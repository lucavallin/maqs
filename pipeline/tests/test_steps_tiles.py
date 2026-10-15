from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps import tiles
from maqs.steps.tiles import BasemapStep, BasePackStep, TerrainStep, format_bbox

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.fixture
def cfg():
    return load_config(REAL)


@pytest.fixture
def veneto(cfg, tmp_path):
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("veneto"),
    )


@pytest.fixture
def fixture_region(cfg, tmp_path):
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("test"),
    )


@pytest.fixture
def versatiles_bin(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/versatiles"))


def test_format_bbox_is_plain_decimal():
    assert format_bbox((10.6231, 44.7923, 13.1021, 46.6806)) == "10.6231,44.7923,13.1021,46.6806"
    assert format_bbox((1e-7, 0.0, 180.0, 90.0)) == "0.0000001,0,180,90"


def test_basemap_argv_and_outputs(veneto, versatiles_bin):
    step = BasemapStep()
    assert step.outputs(veneto) == [veneto.dist / "veneto" / "veneto-basemap.pmtiles"]
    assert step.argv(veneto) == [
        "/usr/bin/versatiles",
        "convert",
        "--bbox",
        "10.6231,44.7923,13.1021,46.6806",
        "--bbox-border",
        "1",
        "--compress",
        "gzip",
        tiles.OSM_SOURCE,
        str(veneto.dist / "veneto" / "veneto-basemap.pmtiles"),
    ]
    e = step.expectation(veneto)
    assert (e.min_zoom, e.max_zoom) == (0, 14) and "mvt" in e.tile_types


def test_terrain_argv_and_outputs(veneto, versatiles_bin):
    step = TerrainStep()
    assert step.outputs(veneto) == [veneto.dist / "veneto" / "veneto-terrain.pmtiles"]
    assert step.argv(veneto) == [
        "/usr/bin/versatiles",
        "convert",
        "--bbox",
        "10.6231,44.7923,13.1021,46.6806",
        "--bbox-border",
        "1",
        "--max-zoom",
        "12",
        tiles.ELEVATION_SOURCE,
        str(veneto.dist / "veneto" / "veneto-terrain.pmtiles"),
    ]
    e = step.expectation(veneto)
    assert (e.min_zoom, e.max_zoom) == (0, 12) and e.tile_types == frozenset({"webp", "png"})


def test_a_region_with_bbox_border_0_gets_no_border_flag(fixture_region, versatiles_bin):
    out = fixture_region.dist / "test"
    assert BasemapStep().argv(fixture_region) == [
        "/usr/bin/versatiles",
        "convert",
        "--bbox",
        "12.21,46.08,12.29,46.13",
        "--compress",
        "gzip",
        tiles.OSM_SOURCE,
        str(out / "test-basemap.pmtiles"),
    ]
    assert TerrainStep().argv(fixture_region) == [
        "/usr/bin/versatiles",
        "convert",
        "--bbox",
        "12.21,46.08,12.29,46.13",
        "--max-zoom",
        "12",
        tiles.ELEVATION_SOURCE,
        str(out / "test-terrain.pmtiles"),
    ]


def test_base_pack_argv_outputs_and_cap(cfg, tmp_path, versatiles_bin):
    ctx = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False)
    step = BasePackStep(cfg.base_pack("triveneto"))
    assert step.name == "base-triveneto"
    assert step.outputs(ctx) == [tmp_path / "base" / "base-triveneto-basemap.pmtiles"]
    assert step.argv(ctx) == [
        "/usr/bin/versatiles",
        "convert",
        "--bbox",
        "10.3818,44.7923,13.9187,47.0921",
        "--max-zoom",
        "10",
        "--compress",
        "gzip",
        tiles.OSM_SOURCE,
        str(tmp_path / "base" / "base-triveneto-basemap.pmtiles"),
    ]
    e = step.expectation(ctx)
    assert (e.min_zoom, e.max_zoom) == (0, 10) and e.size_cap == 15_000_000


def test_build_runs_the_argv(veneto, versatiles_bin, monkeypatch):
    ran = []
    monkeypatch.setattr(tools, "run", lambda argv, **kw: ran.append([str(a) for a in argv]))
    step = BasemapStep()
    assert step.build(veneto) == step.argv(veneto)
    assert ran == [step.argv(veneto)]
