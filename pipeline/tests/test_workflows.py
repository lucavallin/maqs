"""Shape assertions on the workflows: pinned actions, least privilege, no cancellation."""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", ["pipeline.yml", "build-maps.yml", "swift.yml"])
def test_every_action_is_pinned(name):
    doc = load(name)
    uses = [s["uses"] for job in doc["jobs"].values() for s in job["steps"] if "uses" in s]
    assert uses, name
    lines = (WORKFLOWS / name).read_text(encoding="utf-8").splitlines()
    for ref in uses:
        if ref.startswith("actions/"):
            assert re.fullmatch(r"actions/[\w.-]+(/[\w.-]+)*@v\d+", ref), ref
        else:
            assert re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", ref), ref
            for line in (ln for ln in lines if ref in ln):
                assert re.search(r"#\s*v\d", line), line


def test_gh_token_is_scoped_to_the_steps_that_call_gh():
    doc = load("build-maps.yml")
    assert "GH_TOKEN" not in doc.get("env", {})
    for job in doc["jobs"].values():
        assert "GH_TOKEN" not in job.get("env", {})
        for step in job["steps"]:
            calls_gh = re.search(r"\bgh\s", step.get("run", ""))
            assert bool(calls_gh) == ("GH_TOKEN" in step.get("env", {})), step.get("name")


def test_build_maps_writes_only_from_the_release_job():
    doc = load("build-maps.yml")
    assert doc["permissions"] == {"contents": "read"}
    for name, job in doc["jobs"].items():
        perms = job.get("permissions", {})
        if name == "release":
            assert perms == {"contents": "write"}
        else:
            assert "write" not in perms.values()


def test_build_maps_never_cancels_and_publishes_only_full_runs():
    doc = load("build-maps.yml")
    assert doc["concurrency"] == {"group": "build-maps", "cancel-in-progress": False}
    on_key = True if True in doc else "on"  # PyYAML reads the bare key `on` as the boolean True
    assert "schedule" in doc[on_key] and "workflow_dispatch" in doc[on_key]
    release = doc["jobs"]["release"]
    assert "needs.prepare.outputs.full == 'true'" in release["if"]
    assert set(release["needs"]) == {"prepare", "build"}
    run_text = "\n".join(s.get("run", "") for s in release["steps"])
    assert "manifest.json --clobber" in run_text and "--latest" in run_text
    assert run_text.index("release-check") < run_text.index("gh release upload")
    assert run_text.rindex("dist/manifest.json --clobber") > run_text.index("gh release upload")
    manifest_upload = run_text.index('gh release upload "$RELEASE" dist/manifest.json')
    assert run_text.rindex("gh release upload") == manifest_upload
    assert run_text.index('gh release edit "$RELEASE" --latest') > manifest_upload


@pytest.mark.parametrize("name", ["pipeline.yml", "build-maps.yml"])
def test_steps_with_pipes_run_under_bash_pipefail(name):
    for job in load(name)["jobs"].values():
        for step in job["steps"]:
            if "|" in step.get("run", ""):
                assert step.get("shell") == "bash", step.get("name") or step["run"]


def test_build_maps_checkouts_do_not_persist_credentials():
    steps = [s for j in load("build-maps.yml")["jobs"].values() for s in j["steps"]]
    checkouts = [s for s in steps if s.get("uses", "").startswith("actions/checkout@")]
    assert len(checkouts) == 3
    for step in checkouts:
        assert step["with"]["persist-credentials"] is False


def test_build_maps_run_bodies_take_matrix_values_through_env():
    for job in load("build-maps.yml")["jobs"].values():
        for step in job["steps"]:
            assert "${{ matrix." not in step.get("run", ""), step.get("name")


def test_build_restores_the_geofabrik_extracts_strictly():
    steps = load("build-maps.yml")["jobs"]["build"]["steps"]
    restore = next(s for s in steps if s.get("name") == "Restore the Geofabrik extracts")
    assert restore["uses"].startswith("actions/cache/restore@")
    assert restore["with"]["fail-on-cache-miss"] is True
    assert restore["with"]["key"] == "${{ needs.prepare.outputs.geofabrik-key }}"


def test_prepare_caches_every_extract_the_config_names():
    """ADR 0020: the extracts come from maqs regions --json, each fetched once, the cache keyed on
    all their published MD5s, so no extract is hard-coded in the workflow."""
    plan = prepare_step("Plan the run")["run"]
    assert 'echo "extracts=$(jq -c \'.geofabrik_extracts\' <<<"$json")" >> "$GITHUB_OUTPUT"' in plan
    sums = prepare_step("Geofabrik extract checksums")
    assert sums["env"]["EXTRACTS"] == "${{ steps.plan.outputs.extracts }}"
    assert "-latest.osm.pbf.md5" in sums["run"] and "sha256sum" in sums["run"]
    assert "nord-est" not in sums["run"]
    cache = prepare_step("Cache the Geofabrik extracts")
    assert cache["with"]["key"] == "${{ steps.geofabrik.outputs.key }}"
    fetch = prepare_step("Download each extract once")["run"]
    assert 'uv run maqs fetch --extract "$extract"' in fetch


def test_prepare_retries_geofabrik_instead_of_failing_the_month():
    """Six extracts mean six chances of a reset connection; a transient failure is retried with
    curl's doubling backoff for up to five minutes, and a fetch that keeps failing still fails."""
    sums = prepare_step("Geofabrik extract checksums")["run"]
    assert "--retry 8 --retry-all-errors --retry-max-time 300 --connect-timeout 20" in sums
    assert "--retry-delay" not in sums
    fetch = prepare_step("Download each extract once")["run"]
    assert "for attempt in 1 2 3; do" in fetch
    assert '[[ "$attempt" == 3 ]] && exit 1' in fetch


def test_prepare_falls_back_to_the_newest_full_extract_cache_when_geofabrik_is_unreachable():
    """GitHub's runners are sometimes refused by Geofabrik while it answers elsewhere (2026-11-26).
    Then the run takes the newest cache of every extract, by the release workflow's own key shape
    (not pipeline.yml's `geofabrik-nord-est-` cache), says so, and fails only without one."""
    prepare = load("build-maps.yml")["jobs"]["prepare"]
    assert prepare["permissions"] == {"contents": "read", "actions": "read"}
    step = prepare_step("Geofabrik extract checksums")
    assert step["env"]["GH_TOKEN"] == "${{ github.token }}"
    assert step["env"]["GH_REPO"] == "${{ github.repository }}"
    run = step["run"]
    assert "gh cache list --key geofabrik- --sort created_at --order desc" in run
    assert "grep -E '^geofabrik-[0-9a-f]{32}$'" in run
    assert 'echo "fallback=true" >> "$GITHUB_OUTPUT"' in run
    assert 'echo "fallback=false" >> "$GITHUB_OUTPUT"' in run
    assert "::warning::" in run
    assert "no cached extracts to fall back on" in run
    assert prepare["outputs"]["geofabrik-fallback"] == "${{ steps.geofabrik.outputs.fallback }}"


def test_the_release_notes_say_when_the_extracts_came_from_the_cache():
    step = release_step("Check the assets and write the notes")
    assert step["env"]["FALLBACK"] == "${{ needs.prepare.outputs.geofabrik-fallback }}"
    assert '[[ "$FALLBACK" == true ]]' in step["run"]
    assert 'cat >> "$GITHUB_WORKSPACE/notes.md"' in step["run"]
    assert "newest cached extracts" in step["run"]


def release_step(name: str) -> dict:
    steps = load("build-maps.yml")["jobs"]["release"]["steps"]
    return next(s for s in steps if s.get("name") == name)


def test_previous_manifest_is_chosen_by_the_tested_command():
    step = release_step("Fetch the latest published manifest")
    run = step["run"]
    assert "GH_TOKEN" in step["env"] and step["shell"] == "bash"
    assert "gh api \"repos/$GH_REPO/releases\" --paginate | jq -s 'add'" in run
    assert "uv run maqs previous-manifest --releases" in run and '--release "$RELEASE"' in run
    assert 'gh release download "$prev" --pattern manifest.json' in run
    assert "gh release list" not in run and "|| true" not in run


def test_release_check_gets_the_previous_manifest_when_there_is_one():
    step = release_step("Check the assets and write the notes")
    run = step["run"]
    assert step["shell"] == "bash" and "set -euo pipefail" in run
    previous = '"$GITHUB_WORKSPACE/previous/manifest.json"'
    assert f"if [[ -s {previous} ]]; then args+=(--previous {previous}); fi" in run
    assert 'uv run maqs release-check "${args[@]}" | tee "$GITHUB_WORKSPACE/assets.txt"' in run


def test_upload_takes_release_check_paths_under_dist():
    run = release_step("Upload the assets, then the manifest")["run"]
    assert 'files+=("dist/$path")' in run
    assert "find " not in run


def test_summary_shows_how_many_entries_were_carried():
    run = release_step("Summary")["run"]
    assert "carried=$(grep '^carried ' assets.txt)" in run
    assert '"$carried"' in run and "$GITHUB_STEP_SUMMARY" in run


def prepare_step(name: str) -> dict:
    steps = load("build-maps.yml")["jobs"]["prepare"]["steps"]
    return next(s for s in steps if s.get("name") == name)


def test_only_a_run_on_main_is_full_and_publishes():
    plan = prepare_step("Plan the run")["run"]
    gate = (
        'if [[ "$GITHUB_REF" != refs/heads/main ]];'
        ' then echo "not on main: build only"; full=false; fi'
    )
    assert gate in plan
    assert plan.index("then full=true; else full=false; fi") < plan.index(gate)
    assert plan.index(gate) < plan.index('echo "full=$full" >> "$GITHUB_OUTPUT"')
    release_if = load("build-maps.yml")["jobs"]["release"]["if"]
    assert release_if == "needs.prepare.outputs.full == 'true' && github.ref == 'refs/heads/main'"


def test_release_job_has_an_hour():
    assert load("build-maps.yml")["jobs"]["release"]["timeout-minutes"] == 60


def test_disk_space_is_checked_on_each_build_leg_before_the_build():
    jobs = load("build-maps.yml")["jobs"]
    assert not any("df " in s.get("run", "") for s in jobs["prepare"]["steps"])
    names = [s.get("name") for s in jobs["build"]["steps"]]
    disk = jobs["build"]["steps"][names.index("Disk space")]
    assert "df -BG --output=avail /" in disk["run"] and '[[ "$avail" -ge 9 ]]' in disk["run"]
    assert names.index("Disk space") < names.index("Build ${{ matrix.target }}")


def test_prepare_rejects_a_malformed_layers_input():
    plan = prepare_step("Plan the run")["run"]
    check = 'if [[ -n "$LAYERS" && ! "$LAYERS" =~ ^[a-z-]+(,[a-z-]+)*$ ]]; then'
    assert check in plan
    assert plan.index(check) < plan.index('echo "layers=$LAYERS" >> "$GITHUB_OUTPUT"')


def test_gh_release_create_is_off_latest_and_targets_the_built_commit():
    run = release_step("Create the release if the tag is new")["run"]
    line = next(ln for ln in run.splitlines() if "gh release create" in ln)
    assert "--latest=false" in line and '--target "$GITHUB_SHA"' in line


@pytest.mark.parametrize("name", ["pipeline.yml", "build-maps.yml"])
def test_run_bodies_take_no_expressions(name):
    for job in load(name)["jobs"].values():
        for step in job["steps"]:
            assert "${{" not in step.get("run", ""), step.get("name") or step["run"]


def test_pipeline_workflow_runs_when_build_maps_changes():
    doc = load("pipeline.yml")
    on_key = True if True in doc else "on"
    for event in ("push", "pull_request"):
        assert ".github/workflows/build-maps.yml" in doc[on_key][event]["paths"], event


def test_pipeline_workflow_runs_when_swift_workflow_changes():
    doc = load("pipeline.yml")
    on_key = True if True in doc else "on"
    for event in ("push", "pull_request"):
        assert ".github/workflows/swift.yml" in doc[on_key][event]["paths"], event


def test_ios_simulator_step_picks_the_scheme_and_checks_the_log_strictly():
    steps = load("swift.yml")["jobs"]["ios-simulator"]["steps"]
    run = next(s["run"] for s in steps if "xcodebuild -scheme" in s.get("run", ""))
    # The scheme comes from the listing, and a failed listing or a missing scheme fails the step.
    assert "set -o pipefail" in run
    assert "xcodebuild -list -json | jq -e" in run
    assert '"Maqs-Package"' in run and '"Maqs"' in run
    assert 'xcodebuild -scheme "$scheme"' in run
    # The test run's status is captured, not acted on by `set -e`.
    test_call = run.index('xcodebuild -scheme "$scheme"')
    assert run.rindex("set +e", 0, test_call) < test_call < run.index("status=$?")
    # Compiler errors, failed tests and a missing passing summary each fail the step.
    assert "grep -q '\": error:'" in run
    assert "Test run with .* failed" in run and "TEST FAILED" in run
    assert "Test run with [1-9][0-9]* tests.* passed" in run
    assert "tail -50 xcodebuild.log" in run
    assert run.rstrip().endswith('exit "$status"')


def test_swift_jobs_print_the_toolchain_before_building():
    jobs = load("swift.yml")["jobs"]
    macos = [s.get("run", "") for s in jobs["macos"]["steps"]]
    assert macos.index("swift --version") < macos.index("swift build -Xswiftc -warnings-as-errors")
    ios = [s.get("run", "") for s in jobs["ios-simulator"]["steps"]]
    scheme_step = next(i for i, run in enumerate(ios) if "xcodebuild -list" in run)
    assert ios.index("xcodebuild -version") < scheme_step


def test_swift_jobs_make_warnings_errors():
    # Package.swift sets no warning flag (ADR 0018): only these commands fail CI on a warning.
    jobs = load("swift.yml")["jobs"]
    macos = [s.get("run", "") for s in jobs["macos"]["steps"]]
    assert "swift build -Xswiftc -warnings-as-errors" in macos
    assert "swift test -Xswiftc -warnings-as-errors" in macos
    ios = [s.get("run", "") for s in jobs["ios-simulator"]["steps"]]
    test_run = next(run for run in ios if 'xcodebuild -scheme "$scheme"' in run)
    assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test" in test_run


def test_swift_workflow_is_read_only_and_path_filtered():
    doc = load("swift.yml")
    assert doc["permissions"] == {"contents": "read"}
    for job in doc["jobs"].values():
        assert "write" not in job.get("permissions", {}).values()
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout"):
                assert step["with"]["persist-credentials"] is False
    on_key = True if True in doc else "on"
    for event in ("push", "pull_request"):
        paths = doc[on_key][event]["paths"]
        assert "Package.swift" in paths and "Sources/**" in paths and "Tests/**" in paths
        assert not any(p.startswith("pipeline") or p.startswith("docs") for p in paths)
