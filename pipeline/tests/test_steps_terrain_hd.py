from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps.terrain_hd import (
    MAPTERHORN_BASE,
    TerrainHDStep,
    archive_url,
    parse_dry_run_tiles,
    z6_tiles,
)
from maqs.tools import ToolError

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def test_z6_tiles_for_the_test_bbox_is_one_tile():
    assert z6_tiles((12.21, 46.08, 12.29, 46.13)) == [(34, 22)]


def test_z6_tiles_for_veneto_spans_four_archives():
    assert z6_tiles((10.6231, 44.7923, 13.1021, 46.6806)) == [
        (33, 22),
        (33, 23),
        (34, 22),
        (34, 23),
    ]


def test_archive_url():
    assert archive_url(34, 22) == "https://download.mapterhorn.com/6-34-22.pmtiles"


def test_parse_dry_run_tiles():
    text = "2026/10/07 20:51:22 extract.go:450: fetching 4 tiles, 1 chunks, 1 requests\n"
    assert parse_dry_run_tiles(text) == 4
    assert parse_dry_run_tiles("no such line") is None


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("veneto"),
    )


def test_outputs_and_expectation(ctx):
    step = TerrainHDStep()
    assert step.outputs(ctx) == [ctx.dist / "veneto" / "veneto-terrain-hd.pmtiles"]
    e = step.expectation(ctx, step.outputs(ctx)[0])
    assert (e.min_zoom, e.max_zoom) == (13, 13) and e.source == MAPTERHORN_BASE


def test_build_extracts_non_empty_archives_and_merges(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))
    calls = []

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls.append(argv)
        if "--dry-run" in argv:
            empty = "6-33-23" in argv[2] or "6-34-23" in argv[2]
            text = "fetching 0 tiles" if empty else "fetching 100 tiles, 2 chunks, 1 requests"

            class R:
                stdout, stderr = "", text

            return R()
        if argv[1] == "extract":
            Path(argv[3]).write_bytes(b"part")
        if argv[1] == "merge":
            Path(argv[-1]).write_bytes(b"merged")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    step = TerrainHDStep()
    ctx.out_dir.mkdir(parents=True)
    command = step.build(ctx).command
    extracts = [c for c in calls if c[1] == "extract" and "--dry-run" not in c]
    assert [c[2] for c in extracts] == [archive_url(33, 22), archive_url(34, 22)]
    assert all(
        c[-3:] == ["--bbox=10.6231,44.7923,13.1021,46.6806", "--minzoom=13", "--maxzoom=13"]
        for c in extracts
    )
    merges = [c for c in calls if c[1] == "merge"]
    assert len(merges) == 1 and command == merges[0]
    out = step.outputs(ctx)[0]
    assert out.read_bytes() == b"merged" and not list(ctx.out_dir.glob("*.part-*"))


def test_build_with_a_single_archive_skips_merge(tmp_path, monkeypatch):
    cfg = load_config(REAL)
    ctx = BuildContext(
        config=cfg, dist=tmp_path, cache=tmp_path, force=False, region=cfg.region("test")
    )
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        if "--dry-run" in argv:

            class R:
                stdout, stderr = "", "fetching 4 tiles, 1 chunks, 1 requests"

            return R()
        Path(argv[3]).write_bytes(b"part")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    ctx.out_dir.mkdir(parents=True)
    command = TerrainHDStep().build(ctx).command
    assert command[1] == "extract" and TerrainHDStep().outputs(ctx)[0].read_bytes() == b"part"


def test_build_fails_when_every_archive_is_empty(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))

    def fake_run(argv, **kw):
        class R:
            stdout, stderr = "", "fetching 0 tiles"

        return R()

    monkeypatch.setattr(tools, "run", fake_run)
    ctx.out_dir.mkdir(parents=True)
    with pytest.raises(ToolError, match="no high-resolution terrain tiles"):
        TerrainHDStep().build(ctx)


def _runner(ctx_calls, non_empty, fail_on=None):
    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        ctx_calls.append(argv)
        if "--dry-run" in argv:
            n = 5 if any(u in argv[2] for u in non_empty) else 0

            class R:
                stdout, stderr = "", f"fetching {n} tiles"

            return R()
        if fail_on and argv[1] == fail_on:
            raise ToolError(argv, 1, "boom")
        if argv[1] == "extract":
            Path(argv[3]).write_bytes(b"part")
        if argv[1] == "merge":
            Path(argv[-1]).write_bytes(b"merged")
        return None

    return fake_run


def test_single_later_archive_names_that_archive(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))
    calls = []
    monkeypatch.setattr(tools, "run", _runner(calls, ["6-34-23"]))
    ctx.out_dir.mkdir(parents=True)
    step = TerrainHDStep()
    command = step.build(ctx).command
    assert command[2] == archive_url(34, 23) and command[3] == str(step.outputs(ctx)[0])
    assert step.outputs(ctx)[0].read_bytes() == b"part"
    real = [c for c in calls if c[1] == "extract" and "--dry-run" not in c]
    assert len(real) == 1 and real[0][2] == archive_url(34, 23)
    assert not list(ctx.out_dir.glob("*.part-*"))


def test_failed_extract_leaves_no_parts(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))
    calls = []
    runner = _runner(calls, ["6-33-22", "6-34-22"])
    extracts = []

    def run(argv, **kw):
        if "--dry-run" not in [str(a) for a in argv]:
            extracts.append(argv)
            if len(extracts) == 2:
                raise ToolError([str(a) for a in argv], 1, "boom")
        return runner(argv, **kw)

    monkeypatch.setattr(tools, "run", run)
    ctx.out_dir.mkdir(parents=True)
    with pytest.raises(ToolError):
        TerrainHDStep().build(ctx)
    assert list(ctx.out_dir.iterdir()) == []


def test_failed_merge_leaves_no_parts_or_output(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))
    monkeypatch.setattr(tools, "run", _runner([], ["6-33-22", "6-34-22"], fail_on="merge"))
    ctx.out_dir.mkdir(parents=True)
    with pytest.raises(ToolError):
        TerrainHDStep().build(ctx)
    assert list(ctx.out_dir.iterdir()) == []


def test_unparseable_dry_run_raises(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))

    def run(argv, **kw):
        class R:
            stdout, stderr = "", "format changed"

        return R()

    monkeypatch.setattr(tools, "run", run)
    ctx.out_dir.mkdir(parents=True)
    with pytest.raises(ToolError, match="could not read the tile count"):
        TerrainHDStep().build(ctx)
