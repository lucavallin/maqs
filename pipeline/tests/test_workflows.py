"""Shape assertions on the workflows: pinned actions, least privilege, no cancellation."""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", ["pipeline.yml", "build-maps.yml"])
def test_every_action_is_pinned(name):
    doc = load(name)
    uses = [s["uses"] for job in doc["jobs"].values() for s in job["steps"] if "uses" in s]
    assert uses, name
    lines = (WORKFLOWS / name).read_text(encoding="utf-8").splitlines()
    for ref in uses:
        if ref.startswith("actions/"):
            assert re.fullmatch(r"actions/[\w.-]+@v\d+", ref), ref
        else:
            assert re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", ref), ref
            line = next(ln for ln in lines if ref in ln)
            assert re.search(r"#\s*v\d", line), line


def test_gh_token_is_scoped_to_the_steps_that_call_gh():
    doc = load("build-maps.yml")
    for job in doc["jobs"].values():
        assert "GH_TOKEN" not in job.get("env", {})
        for step in job["steps"]:
            calls_gh = re.search(r"\bgh release\b", step.get("run", ""))
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
