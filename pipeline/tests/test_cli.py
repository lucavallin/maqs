import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from maqs import cli, tools
from maqs.cli import DEFAULT_LAYERS, LAYER_ORDER, LAYER_STEPS, _parse_layers, main
from maqs.steps import tiles
from maqs.steps.base import StepResult
from maqs.tools import ToolStatus
from tests.helpers import write_pmtiles
from tests.manifest_fixtures import base_report, region_report, write_dist

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def ok_tools(monkeypatch):
    statuses = [ToolStatus(n, v, v, Path(f"/fake/{n}"), True, "ok") for n, v in tools.PINS.items()]
    monkeypatch.setattr(cli, "check_tools", lambda: statuses)


def build(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "build", *args])


def fake_run_writing_archives(argv, **kw):
    argv = [str(a) for a in argv]
    out = Path(argv[-1])
    out.parent.mkdir(parents=True, exist_ok=True)
    if "elevation.versatiles" in argv[-2]:
        write_pmtiles(out, tile_type=4, max_zoom=12, tile_compression=1)
    else:
        write_pmtiles(out, tile_type=1, max_zoom=14, metadata={"attribution": "© OSM"})


def test_regions_lists_ids_extracts_and_base_packs(monkeypatch):
    result = CliRunner().invoke(main, ["--config", str(REAL), "regions"])
    assert result.exit_code == 0
    for s in (
        "test",
        "triveneto",
        "veneto",
        "europe/italy/nord-est",
        "base-triveneto",
        "10.3818,44.7923,13.9187,47.0921",
    ):
        assert s in result.output


def test_check_tools_exit_codes(monkeypatch):
    ok_tools(monkeypatch)
    assert CliRunner().invoke(main, ["check-tools"]).exit_code == 0
    bad = [
        ToolStatus("versatiles", "5.0.0", "4.9.0", Path("/x"), False, "found 4.9.0, pinned 5.0.0")
    ]
    monkeypatch.setattr(cli, "check_tools", lambda: bad)
    result = CliRunner().invoke(main, ["check-tools"])
    assert result.exit_code == 1 and "4.9.0" in result.output


def test_build_refuses_unknown_region(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = build("--region", "nope", "--dist", str(tmp_path))
    assert result.exit_code == 2
    assert "unknown region 'nope'" in result.output and "veneto" in result.output


def test_build_refuses_a_base_pack_id_as_region(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = build("--region", "base-triveneto", "--dist", str(tmp_path))
    assert result.exit_code == 2 and "--region base" in result.output


def test_build_refuses_unknown_layer(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = build("--region", "test", "--layers", "lava", "--dist", str(tmp_path))
    assert result.exit_code == 2 and "unknown layer 'lava'" in result.output


def test_build_refuses_an_empty_layer_list(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = build("--region", "test", "--layers", " , ", "--dist", str(tmp_path))
    assert result.exit_code == 2 and "--layers must name at least one layer" in result.output
    assert not (tmp_path / "test").exists()


def test_build_base_refuses_a_config_without_base_packs(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    no_packs = tmp_path / "regions.yaml"
    no_packs.write_text(
        "schema_version: 1\n"
        "regions:\n"
        "  - { id: solo, name: { it: Solo, en: Solo }, bbox: [12.2, 46.0, 12.3, 46.1] }\n"
    )
    result = CliRunner().invoke(
        main, ["--config", str(no_packs), "build", "--region", "base", "--dist", str(tmp_path)]
    )
    assert result.exit_code == 2 and "no base_packs" in result.output


def test_missing_config_file_is_a_usage_error(tmp_path):
    result = CliRunner().invoke(main, ["--config", str(tmp_path / "absent.yaml"), "regions"])
    assert result.exit_code == 2


def test_build_stops_on_tool_mismatch(monkeypatch, tmp_path):
    bad = [
        ToolStatus("versatiles", "5.0.0", "4.9.0", Path("/x"), False, "found 4.9.0, pinned 5.0.0")
    ]
    monkeypatch.setattr(cli, "check_tools", lambda: bad)

    def must_not_run(argv, **kw):
        raise AssertionError(f"a step ran despite the tool mismatch: {argv}")

    monkeypatch.setattr(tools, "run", must_not_run)
    result = build("--region", "test", "--dist", str(tmp_path))
    assert result.exit_code == 1 and "pinned 5.0.0" in result.output
    assert not (tmp_path / "test").exists()


def test_default_dist_and_cache_sit_under_the_repo_root_not_the_cwd(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))
    monkeypatch.setattr(tools, "run", fake_run_writing_archives)
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    config = repo / "config" / "regions.yaml"
    config.write_text(REAL.read_text())
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    seen = {}
    real_run_build = cli.run_build

    def recording_run_build(cfg, **kw):
        seen.update(kw)
        return real_run_build(cfg, **kw)

    monkeypatch.setattr(cli, "run_build", recording_run_build)
    result = CliRunner().invoke(
        main, ["--config", str(config), "build", "--region", "test", "--layers", "basemap,terrain"]
    )
    assert result.exit_code == 0, result.output
    assert (repo / "dist" / "test" / "test-basemap.v1.pmtiles").exists()
    assert (repo / "dist" / "test" / "build-report.json").exists()
    assert seen["dist"] == repo / "dist" and seen["cache"] == repo / ".cache"
    assert not (elsewhere / "dist").exists()


def test_build_help_names_the_repo_root_defaults():
    result = CliRunner().invoke(main, ["build", "--help"])
    assert result.exit_code == 0
    assert "dist/ under the repo root" in result.output
    assert ".cache/ under the repo root" in result.output


def test_build_runs_steps_and_writes_report(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))
    monkeypatch.setattr(tools, "run", fake_run_writing_archives)
    result = build("--region", "test", "--layers", "basemap,terrain", "--dist", str(tmp_path))
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert [s["name"] for s in report["steps"]] == ["basemap", "terrain"]
    assert report["validation"]["ok"] is True
    assert report["tools"] == tools.PINS
    sources = [s["outputs"][0]["source"] for s in report["steps"]]
    assert sources == [tiles.OSM_SOURCE, tiles.ELEVATION_SOURCE]
    assert (tmp_path / "test" / "test-basemap.v1.pmtiles").exists()
    second = build("--region", "test", "--layers", "basemap,terrain", "--dist", str(tmp_path))
    assert second.exit_code == 0 and "skipped" in second.output


def test_fixture_over_the_size_warning_names_both_levers(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))
    monkeypatch.setattr(tools, "run", fake_run_writing_archives)
    monkeypatch.setattr(cli, "TEST_REGION_WARN", 0)
    result = build("--region", "test", "--layers", "basemap,terrain", "--dist", str(tmp_path))
    assert result.exit_code == 0, result.output
    assert "warning: test basemap+terrain is" in result.output
    assert "shrink its bbox or set bbox_border: 0" in result.output


def test_build_exit_1_when_a_step_fails(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        raise tools.ToolError([str(a) for a in argv], 1, "network down")

    monkeypatch.setattr(tools, "run", fake_run)
    result = build("--region", "test", "--layers", "basemap,terrain", "--dist", str(tmp_path))
    assert result.exit_code == 1 and "network down" in result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is False


@pytest.mark.parametrize(
    "error",
    [
        pytest.param(lambda argv: tools.ToolError(argv, 1, "network down"), id="tool-error"),
        pytest.param(lambda argv: tools.ToolMissing("versatiles"), id="tool-missing"),
    ],
)
def test_build_all_reports_every_region_when_the_first_fails(monkeypatch, tmp_path, error):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        if Path(argv[-1]).parent.name == "test":
            raise error(argv)
        return fake_run_writing_archives(argv, **kw)

    monkeypatch.setattr(tools, "run", fake_run)
    result = build("--region", "all", "--layers", "basemap,terrain", "--dist", str(tmp_path))
    assert result.exit_code == 1
    assert "build failed for: test (see build-report.json)" in result.output
    region_ids = ["test", "triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige"]
    reports = {
        rid: json.loads((tmp_path / rid / "build-report.json").read_text()) for rid in region_ids
    }
    assert reports["test"]["validation"]["ok"] is False
    assert [s["status"] for s in reports["test"]["steps"]] == ["failed", "failed"]
    assert all(reports[rid]["validation"]["ok"] for rid in region_ids[1:])


def test_build_base_packs(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        out = Path(str(argv[-1]))
        out.parent.mkdir(parents=True, exist_ok=True)
        write_pmtiles(out, tile_type=1, max_zoom=10)
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    result = build("--region", "base", "--dist", str(tmp_path))
    assert result.exit_code == 0, result.output
    assert (tmp_path / "base" / "base-triveneto-basemap.v1.pmtiles").exists()
    report = json.loads((tmp_path / "base" / "build-report.json").read_text())
    assert report["region"] == "base" and report["validation"]["ok"] is True
    assert [s["name"] for s in report["steps"]] == ["base-triveneto"]
    assert report["steps"][0]["outputs"][0]["file"] == "base-triveneto-basemap.v1.pmtiles"


def test_build_base_puts_every_pack_in_one_report(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        out = Path(str(argv[-1]))
        out.parent.mkdir(parents=True, exist_ok=True)
        write_pmtiles(out, tile_type=1, max_zoom=int(argv[argv.index("--max-zoom") + 1]))

    monkeypatch.setattr(tools, "run", fake_run)
    config = tmp_path / "regions.yaml"
    config.write_text(
        "schema_version: 1\n"
        "base_packs:\n"
        "  - { id: north, regions: [a], max_zoom: 8 }\n"
        "  - { id: south, regions: [b], max_zoom: 9 }\n"
        "regions:\n"
        "  - { id: a, name: { it: A, en: A }, bbox: [12.2, 46.0, 12.3, 46.1] }\n"
        "  - { id: b, name: { it: B, en: B }, bbox: [12.2, 45.0, 12.3, 45.1] }\n"
    )
    dist = tmp_path / "dist"
    result = CliRunner().invoke(
        main, ["--config", str(config), "build", "--region", "base", "--dist", str(dist)]
    )
    assert result.exit_code == 0, result.output
    assert sorted(p.name for p in (dist / "base").iterdir()) == [
        "base-north-basemap.v1.pmtiles",
        "base-south-basemap.v1.pmtiles",
        "build-report.json",
    ]
    report = json.loads((dist / "base" / "build-report.json").read_text())
    assert report["region"] == "base"
    assert [s["name"] for s in report["steps"]] == ["base-north", "base-south"]
    assert [s["outputs"][0]["max_zoom"] for s in report["steps"]] == [8, 9]


def test_default_layers_include_the_data_layers_in_build_order():
    assert DEFAULT_LAYERS == ("basemap", "terrain", "trails", "places", "curvature")
    assert LAYER_ORDER == ("basemap", "terrain", "terrain-hd", "trails", "places", "curvature")
    assert set(LAYER_STEPS) == set(LAYER_ORDER)
    assert "basemap,terrain,trails,places,curvature" in (
        CliRunner().invoke(main, ["build", "--help"]).output.replace("\n", "").replace(" ", "")
    )


def test_parse_layers_sorts_by_build_order_and_drops_duplicates():
    assert _parse_layers(None) == list(DEFAULT_LAYERS)
    assert _parse_layers("curvature,basemap,trails,basemap") == ["basemap", "trails", "curvature"]
    assert _parse_layers("terrain-hd,terrain") == ["terrain", "terrain-hd"]


def test_build_runs_the_default_layers_in_order_without_terrain_hd(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    ran: list[str] = []

    def fake_run_step(step, ctx):
        ran.append(step.name)
        return StepResult(step.name, "built", 0.0)

    monkeypatch.setattr(cli, "run_step", fake_run_step)
    result = build("--region", "test", "--dist", str(tmp_path))
    assert result.exit_code == 0, result.output
    assert ran == ["basemap", "terrain", "trails", "places", "curvature"]


def check_config(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "check-config", *args])


def test_check_config_passes_on_the_real_files():
    result = check_config()
    assert result.exit_code == 0, result.output
    assert "ok: regions.yaml" in result.output and "ok: sources.json" in result.output


def test_check_config_rejects_a_bad_sources_file(tmp_path):
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    (cfg_dir / "regions.yaml").write_text(REAL.read_text())
    bad = json.loads((REAL.parent / "sources.json").read_text())
    bad["layers"]["basemap"][0]["tiles"] = "http://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"
    (cfg_dir / "sources.json").write_text(json.dumps(bad))
    result = CliRunner().invoke(main, ["--config", str(cfg_dir / "regions.yaml"), "check-config"])
    assert result.exit_code == 2
    assert "sources.json: /layers/basemap/0/tiles" in result.output


def test_check_config_validates_a_manifest(tmp_path):
    from tests.test_schemas import MANIFEST

    good = tmp_path / "manifest.json"
    good.write_text(json.dumps(MANIFEST))
    assert check_config("--manifest", str(good)).exit_code == 0
    bad_doc = json.loads(good.read_text())
    bad_doc["regions"][0]["layers"]["trails"][0]["url"] = (
        "https://github.com/lucavallin/maqs/releases/latest/download/veneto-trails.v1.sqlite"
    )
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(bad_doc))
    result = check_config("--manifest", str(bad))
    assert result.exit_code == 2 and "/regions/0/layers/trails/0/url" in result.output


ALL_REGIONS = ("triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige")


def manifest_cmd(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "manifest", *args])


def full_dist(tmp_path):
    reports = {r: region_report(r) for r in ALL_REGIONS}
    reports["test"] = region_report("test")
    reports["base"] = base_report(["triveneto"])
    return write_dist(tmp_path / "dist", reports)


def test_manifest_command_writes_a_valid_manifest(tmp_path):
    dist = full_dist(tmp_path)
    result = manifest_cmd("--release", "data-2026-11", "--dist", str(dist))
    assert result.exit_code == 0, result.output
    out = dist / "manifest.json"
    assert "wrote" in result.output and out.exists()
    doc = json.loads(out.read_text())
    assert doc["release"] == "data-2026-11"
    assert [r["id"] for r in doc["regions"]] == list(ALL_REGIONS)
    assert check_config("--manifest", str(out)).exit_code == 0


def test_manifest_command_fails_on_a_missing_region(tmp_path):
    dist = full_dist(tmp_path)
    (dist / "veneto" / "build-report.json").unlink()
    result = manifest_cmd("--release", "data-2026-11", "--dist", str(dist))
    assert result.exit_code == 1 and "veneto: build-report.json not found" in result.output
    assert not (dist / "manifest.json").exists()


def test_manifest_command_rejects_a_bad_release_tag(tmp_path):
    dist = full_dist(tmp_path)
    assert manifest_cmd("--release", "latest", "--dist", str(dist)).exit_code == 2
    assert manifest_cmd("--release", "data-ci", "--dist", str(dist)).exit_code == 2
    refused = manifest_cmd("--release", "data-2026-11", "--dist", str(dist), "--regions", "test")
    assert refused.exit_code == 2


def test_manifest_command_data_ci_covers_only_the_listed_regions(tmp_path):
    reports = {"test": region_report("test"), "base": base_report(["triveneto"])}
    dist = write_dist(tmp_path / "dist", reports)
    result = manifest_cmd("--release", "data-ci", "--dist", str(dist), "--regions", "test")
    assert result.exit_code == 0, result.output
    assert "(1 regions, 1 base packs)" in result.output
    doc = json.loads((dist / "manifest.json").read_text())
    assert [r["id"] for r in doc["regions"]] == ["test"]


def test_manifest_command_applies_previous(tmp_path):
    dist = full_dist(tmp_path)
    previous = tmp_path / "previous.json"
    first = manifest_cmd("--release", "data-2026-10", "--dist", str(dist), "--out", str(previous))
    assert first.exit_code == 0
    # The new build ships curvature schema 2; the previous release's v1 entries are carried over.
    report_file = dist / "veneto" / "build-report.json"
    report = json.loads(report_file.read_text())
    for s in report["steps"]:
        if s["name"] == "curvature":
            s["outputs"][0]["layer_schema_version"] = 2
            s["outputs"][0]["file"] = s["outputs"][0]["file"].replace(".v1.", ".v2.")
    report_file.write_text(json.dumps(report))
    result = manifest_cmd(
        "--release", "data-2026-11", "--dist", str(dist), "--previous", str(previous)
    )
    assert result.exit_code == 0, result.output
    doc = json.loads((dist / "manifest.json").read_text())
    veneto = next(r for r in doc["regions"] if r["id"] == "veneto")
    assert [e["layer_schema_version"] for e in veneto["layers"]["curvature"]] == [2, 1]
    carried = veneto["layers"]["curvature"][1]["url"]
    assert carried.endswith("/data-2026-10/veneto-curvature.v1.sqlite")
    other = next(r for r in doc["regions"] if r["id"] == "triveneto")
    # Same version in both releases: not carried.
    assert [e["layer_schema_version"] for e in other["layers"]["curvature"]] == [1]


def test_manifest_command_fails_on_an_unreadable_previous(tmp_path):
    dist = full_dist(tmp_path)
    broken = tmp_path / "previous.json"
    broken.write_text("{not json")
    result = manifest_cmd(
        "--release", "data-2026-11", "--dist", str(dist), "--previous", str(broken)
    )
    assert result.exit_code == 1 and "--previous" in result.output


def test_manifest_command_refuses_a_previous_that_fails_the_schema(tmp_path):
    dist = full_dist(tmp_path)
    previous = tmp_path / "previous.json"
    first = manifest_cmd("--release", "data-2026-10", "--dist", str(dist), "--out", str(previous))
    assert first.exit_code == 0, first.output
    doc = json.loads(previous.read_text())
    doc["regions"][0]["layers"]["trails"][0]["sha256"] = "not-a-digest"
    previous.write_text(json.dumps(doc))
    result = manifest_cmd(
        "--release", "data-2026-11", "--dist", str(dist), "--previous", str(previous)
    )
    assert result.exit_code == 1
    assert f"--previous {previous}: /regions/0/layers/trails/0/sha256: " in result.output
    assert not (dist / "manifest.json").exists()


@pytest.mark.parametrize("tag", ["data-2026-13", "data-2026-00", "data-2026-11\n"])
def test_manifest_command_rejects_a_month_outside_01_to_12(tmp_path, tag):
    dist = full_dist(tmp_path)
    result = manifest_cmd("--release", tag, "--dist", str(dist))
    assert result.exit_code == 2 and "--release must look like data-YYYY-MM" in result.output


def test_manifest_command_says_how_many_entries_it_carried(tmp_path):
    dist = full_dist(tmp_path)
    previous = tmp_path / "previous.json"
    first = manifest_cmd("--release", "data-2026-10", "--dist", str(dist), "--out", str(previous))
    assert first.exit_code == 0 and "carried" not in first.output
    same = manifest_cmd(
        "--release", "data-2026-11", "--dist", str(dist), "--previous", str(previous)
    )
    assert same.exit_code == 0 and "carried 0 entries from data-2026-10" in same.output
    report_file = dist / "veneto" / "build-report.json"
    report = json.loads(report_file.read_text())
    for s in report["steps"]:
        if s["name"] == "trails":
            for o in s["outputs"]:
                o["layer_schema_version"] = 2
                o["file"] = o["file"].replace(".v1.", ".v2.")
    report_file.write_text(json.dumps(report))
    bumped = manifest_cmd(
        "--release", "data-2026-11", "--dist", str(dist), "--previous", str(previous)
    )
    assert bumped.exit_code == 0 and "carried 2 entries from data-2026-10" in bumped.output


def test_regions_json_lists_regions_base_packs_and_extracts():
    result = CliRunner().invoke(main, ["--config", str(REAL), "regions", "--json"])
    assert result.exit_code == 0, result.output
    doc = json.loads(result.output)
    ids = [r["id"] for r in doc["regions"]]
    assert ids == ["test", "triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige"]
    test = doc["regions"][0]
    assert test["fixture"] is True and test["geofabrik"] == "europe/italy/nord-est"
    assert test["name"] == {"it": "Nevegal (test)", "en": "Nevegal (test)"}
    assert test["bbox"] == [12.21, 46.08, 12.29, 46.13]
    assert all(r["fixture"] is False for r in doc["regions"][1:])
    assert doc["base_packs"] == [{"id": "triveneto", "regions": ["triveneto"], "max_zoom": 10}]
    assert doc["geofabrik_extracts"] == ["europe/italy/nord-est"]
    assert [r["id"] for r in doc["regions"] if not r["fixture"]] == ids[1:]


def fetch(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "fetch", *args])


def test_fetch_downloads_the_named_extract(monkeypatch, tmp_path):
    calls = []

    def fake_fetch(cache, extract):
        calls.append((cache, extract))
        p = cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"pbf")
        return p

    monkeypatch.setattr(cli.extract, "fetch_extract", fake_fetch)
    result = fetch("--extract", "europe/italy/nord-est", "--cache", str(tmp_path))
    assert result.exit_code == 0, result.output
    assert calls == [(tmp_path, "europe/italy/nord-est")]
    assert "ok:" in result.output and "3 bytes" in result.output


def test_fetch_rejects_an_unknown_extract(tmp_path):
    result = fetch("--extract", "europe/nowhere", "--cache", str(tmp_path))
    assert result.exit_code == 2 and "europe/italy/nord-est" in result.output


def test_fetch_reports_a_download_failure(monkeypatch, tmp_path):
    def boom(cache, extract):
        raise cli.extract.FetchError("md5 mismatch for x")

    monkeypatch.setattr(cli.extract, "fetch_extract", boom)
    result = fetch("--extract", "europe/italy/nord-est", "--cache", str(tmp_path))
    assert result.exit_code == 1 and "md5 mismatch" in result.output


def test_release_check_passes_and_writes_notes(tmp_path):
    from tests.test_release import write_assets
    from tests.test_schemas import MANIFEST

    doc = json.loads(json.dumps(MANIFEST))
    write_assets(tmp_path / "dist", doc)
    (tmp_path / "manifest.json").write_text(json.dumps(doc))
    result = CliRunner().invoke(
        main,
        [
            "--config",
            str(REAL),
            "release-check",
            "--dist",
            str(tmp_path / "dist"),
            "--manifest",
            str(tmp_path / "manifest.json"),
            "--notes",
            str(tmp_path / "notes.md"),
        ],
    )
    assert result.exit_code == 0, result.output
    assert "veneto-trails.v1.sqlite 1234" in result.output and "total " in result.output
    assert (tmp_path / "notes.md").read_text().startswith("# Map data 2026-11")


def test_release_check_fails_on_a_missing_asset(tmp_path):
    from tests.test_release import write_assets
    from tests.test_schemas import MANIFEST

    doc = json.loads(json.dumps(MANIFEST))
    write_assets(tmp_path / "dist", doc)
    (tmp_path / "dist" / "base" / "base-triveneto-basemap.v1.pmtiles").unlink()
    (tmp_path / "manifest.json").write_text(json.dumps(doc))
    result = CliRunner().invoke(
        main,
        [
            "--config",
            str(REAL),
            "release-check",
            "--dist",
            str(tmp_path / "dist"),
            "--manifest",
            str(tmp_path / "manifest.json"),
        ],
    )
    assert result.exit_code == 1 and "base-triveneto-basemap.v1.pmtiles: missing" in result.output
