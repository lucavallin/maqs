import dataclasses
import json
import subprocess
from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.geometry import decode_polyline
from maqs.osm import extract
from maqs.pmtiles_reader import zxy_to_tile_id
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from maqs.trails.step import TrailsStep
from maqs.validate import SqliteExpectation
from tests.helpers import write_pmtiles
from tests.osm_fixtures import write_osm
from tests.test_terrain_sampler import terrarium_tile

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
P = {
    1: (12.250, 46.100),
    2: (12.251, 46.101),
    3: (12.252, 46.102),
    4: (12.253, 46.103),
    5: (12.260, 46.110),
}


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("test"),
    )


@pytest.fixture
def hiking(tmp_path):
    return write_osm(
        tmp_path / "hiking.osm.pbf",
        {k: P[k] for k in P},
        {10: ([1, 2, 3], {"highway": "path"}), 11: ([3, 4, 5], {"highway": "path"})},
        {
            100: (
                [("w", 10, ""), ("w", 11, "")],
                {
                    "type": "route",
                    "route": "hiking",
                    "ref": "501",
                    "name": "Alta Via",
                    "cai_scale": "E",
                },
            ),
            101: (
                [("w", 10, ""), ("w", 99, "")],
                {"type": "route", "route": "hiking", "ref": "502"},
            ),
        },
    )


@pytest.fixture
def stubs(ctx, hiking, monkeypatch):
    monkeypatch.setattr(extract, "region_hiking_pbf", lambda c: hiking)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: hiking)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))
    calls = {}

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls["argv"] = argv
        src = Path(argv[-1])
        calls["features"] = [
            json.loads(line) for line in src.read_text().splitlines() if line.strip()
        ]
        out = Path(argv[argv.index("-o") + 1])
        write_pmtiles(out, tile_type=1, min_zoom=6, max_zoom=14)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(tools, "run", fake_run)
    return calls


def test_outputs_and_expectations(ctx):
    step = TrailsStep()
    sqlite, pmtiles = step.outputs(ctx)
    assert (
        sqlite == ctx.dist / "test" / "test-trails.sqlite"
        and pmtiles == ctx.dist / "test" / "test-trails.pmtiles"
    )
    e = step.expectation(ctx, sqlite)
    assert (
        isinstance(e, SqliteExpectation)
        and e.layer == "trails"
        and e.region == "test"
        and e.row_ranges == {}
    )
    e2 = step.expectation(ctx, pmtiles)
    assert (e2.min_zoom, e2.max_zoom) == (6, 14) and e2.tile_types == frozenset({"mvt"})


def test_expectation_carries_the_region_row_range(ctx):
    cfg = ctx.config
    veneto = BuildContext(
        config=cfg, dist=ctx.dist, cache=ctx.cache, force=False, region=cfg.region("veneto")
    )
    e = TrailsStep().expectation(veneto, veneto.out_dir / "veneto-trails.sqlite")
    assert e.row_ranges["trails"].min == 1500


def test_build_writes_sqlite_overlay_and_anomalies(ctx, stubs):
    result = run_step(TrailsStep(), ctx)
    assert result.status == "built", result.error
    assert result.command == stubs["argv"]
    assert (
        stubs["argv"][:2] == ["/usr/bin/tippecanoe", "-o"]
        and "-l" in stubs["argv"]
        and "-Z6" in stubs["argv"]
        and "-z14" in stubs["argv"]
    )
    conn = open_readonly(ctx.out_dir / "test-trails.sqlite")
    rows = conn.execute(
        "SELECT id, ref, name, difficulty, geometry_status, length_m, ascent_m, geometry "
        "FROM trails ORDER BY id"
    ).fetchall()
    assert [(r[1], r[3], r[4]) for r in rows] == [
        ("501", 2, "ordered"),
        ("502", None, "incomplete"),
    ]
    assert decode_polyline(rows[0][7])[0] == pytest.approx(P[1], abs=1e-6) and rows[0][5] > 1000
    assert rows[0][6] is None  # no terrain archive in this build
    assert conn.execute(
        "SELECT rowid FROM trails_fts WHERE trails_fts MATCH 'alta'"
    ).fetchall() == [(1,)]
    assert conn.execute("SELECT count(*) FROM trails_rtree").fetchone() == (2,)
    kinds = {a.kind for a in result.anomalies}
    assert {"missing_member", "terrain_missing"} <= kinds
    assert [f["properties"]["ref"] for f in stubs["features"]] == ["501", "502"]
    assert (
        stubs["features"][0]["geometry"]["type"] == "LineString"
        and stubs["features"][0]["properties"]["id"] == 1
    )
    assert result.outputs[0].rows == {"trails": 2} and result.outputs[1].tile_type == "mvt"


def test_build_computes_ascent_from_the_terrain_archive(ctx, stubs):
    ctx.out_dir.mkdir(parents=True)
    tile = terrarium_tile(lambda px, py: 1000.0 + 2.0 * px)  # 2 m per pixel eastwards
    write_pmtiles(
        ctx.out_dir / "test-terrain.pmtiles",
        tile_type=4,
        min_zoom=0,
        max_zoom=12,
        tile_compression=1,
        tile=tile,
        tile_id=zxy_to_tile_id(12, 2187, 1455),
    )
    result = run_step(TrailsStep(), ctx)
    assert result.status == "built", result.error
    conn = open_readonly(ctx.out_dir / "test-trails.sqlite")
    ascent, descent = conn.execute(
        "SELECT ascent_m, descent_m FROM trails WHERE ref = '501'"
    ).fetchone()
    assert (
        ascent is not None and ascent > 0 and descent == 0.0
    )  # the trail runs east, uphill on this tile
    assert "terrain_missing" not in {a.kind for a in result.anomalies}


def test_secondary_rows_point_at_their_winner(ctx, stubs):
    cfg = ctx.config
    # pretend the region lists the osm source twice: the second copy must become secondary rows
    region = dataclasses.replace(cfg.region("test"), trail_sources=("osm", "osm"))
    ctx2 = BuildContext(config=cfg, dist=ctx.dist, cache=ctx.cache, force=False, region=region)
    result = run_step(TrailsStep(), ctx2)
    assert result.status == "built", result.error
    conn = open_readonly(ctx2.out_dir / "test-trails.sqlite")
    assert conn.execute(
        "SELECT count(*) FROM trails WHERE secondary_of IS NOT NULL"
    ).fetchone() == (2,)
    assert conn.execute("SELECT secondary_of FROM trails WHERE id = 3").fetchone() == (1,)
    assert len(stubs["features"]) == 2  # overlays carry primaries only


def test_build_stores_null_ascent_when_no_sample_has_a_terrain_tile(ctx, stubs):
    ctx.out_dir.mkdir(parents=True)
    tile = terrarium_tile(lambda px, py: 1000.0)
    write_pmtiles(
        ctx.out_dir / "test-terrain.pmtiles",
        tile_type=4,
        min_zoom=0,
        max_zoom=12,
        tile_compression=1,
        tile=tile,
        tile_id=zxy_to_tile_id(12, 0, 0),
    )  # far from the trail
    result = run_step(TrailsStep(), ctx)
    assert result.status == "built", result.error
    conn = open_readonly(ctx.out_dir / "test-trails.sqlite")
    assert conn.execute("SELECT ascent_m, descent_m FROM trails WHERE ref = '501'").fetchone() == (
        None,
        None,
    )
    no_coverage = [a for a in result.anomalies if a.kind == "terrain_no_coverage"]
    assert [a.id for a in no_coverage] == ["relation/100", "relation/101"]
    assert "samples without a terrain tile" in no_coverage[0].message
    assert "terrain_missing" not in {a.kind for a in result.anomalies}
