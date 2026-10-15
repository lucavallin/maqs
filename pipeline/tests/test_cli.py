import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from maqs import cli, tools
from maqs.cli import main
from maqs.tools import ToolStatus
from tests.helpers import write_pmtiles

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
    assert result.exit_code == 2 and "no layers" in result.output
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
    result = CliRunner().invoke(main, ["--config", str(config), "build", "--region", "test"])
    assert result.exit_code == 0, result.output
    assert (repo / "dist" / "test" / "test-basemap.pmtiles").exists()
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
    result = build("--region", "test", "--dist", str(tmp_path))
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert [s["name"] for s in report["steps"]] == ["basemap", "terrain"]
    assert report["validation"]["ok"] is True
    assert report["tools"] == tools.PINS
    assert (tmp_path / "test" / "test-basemap.pmtiles").exists()
    second = build("--region", "test", "--dist", str(tmp_path))
    assert second.exit_code == 0 and "skipped" in second.output


def test_build_exit_1_when_a_step_fails(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        raise tools.ToolError([str(a) for a in argv], 1, "network down")

    monkeypatch.setattr(tools, "run", fake_run)
    result = build("--region", "test", "--dist", str(tmp_path))
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
    result = build("--region", "all", "--dist", str(tmp_path))
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
    assert (tmp_path / "base" / "base-triveneto-basemap.pmtiles").exists()
    report = json.loads((tmp_path / "base" / "build-report.json").read_text())
    assert report["region"] == "base" and report["validation"]["ok"] is True
    assert [s["name"] for s in report["steps"]] == ["base-triveneto"]
    assert report["steps"][0]["outputs"][0]["file"] == "base-triveneto-basemap.pmtiles"


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
        "base-north-basemap.pmtiles",
        "base-south-basemap.pmtiles",
        "build-report.json",
    ]
    report = json.loads((dist / "base" / "build-report.json").read_text())
    assert report["region"] == "base"
    assert [s["name"] for s in report["steps"]] == ["base-north", "base-south"]
    assert [s["outputs"][0]["max_zoom"] for s in report["steps"]] == [8, 9]
