import dataclasses

import pytest

from maqs.config import CurvatureConfig, RowRange
from maqs.context import BuildContext
from maqs.curvature.step import CurvatureStep, parse_oneway, read_roads
from maqs.geometry import bbox_of, decode_polyline
from maqs.osm import extract
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from tests.osm_fixtures import write_osm
from tests.step_fixtures import stub_tags_filter
from tests.test_curvature import arc, east


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("yes", 1),
        ("true", 1),
        ("1", 1),
        ("-1", -1),
        ("no", 0),
        (None, 0),
        ("reversible", 0),
    ],
)
def test_parse_oneway(raw, expected):
    assert parse_oneway(raw) == expected


def roads_pbf(tmp_path):
    bend = arc(50.0, 180, 270, 6)
    straight = east(3)
    two = east(2)
    nodes = {i + 1: c for i, c in enumerate(bend)}  # 1..7
    base = len(nodes)
    nodes.update({base + i + 1: c for i, c in enumerate(straight)})  # 8..10
    nodes.update({base + 3 + i + 1: c for i, c in enumerate(two)})  # 11..12
    nodes[99] = (12.30, 46.15)
    passo = {
        "highway": "tertiary",
        "name": "Via del Passo",
        "ref": "SP1",
        "surface": "asphalt",
        "oneway": "yes",
        "maxspeed": "50",
    }
    ways = {
        10: (list(range(1, 8)), passo),
        11: (list(range(8, 11)), {"highway": "primary"}),  # three collinear nodes
        12: ([11, 12], {"highway": "secondary"}),  # two nodes: kept with score 0
        # not a configured class (osmium filters it in real runs; the reader must still skip it)
        13: ([8, 9], {"highway": "track"}),
        14: ([9, 10], {"highway": "primary", "surface": "gravel"}),  # excluded surface
        15: ([99], {"highway": "primary"}),  # one node: skipped with an anomaly
    }
    return write_osm(tmp_path / "roads.osm.pbf", nodes, ways, {})


def test_read_roads_filters_and_scores(tmp_path):
    cfg = CurvatureConfig(("primary", "secondary", "tertiary"), ("gravel",))
    segments, anomalies = read_roads(roads_pbf(tmp_path), cfg)
    by_way = {s.osm_way_id: s for s in segments}
    assert set(by_way) == {10, 11, 12}
    s = by_way[10]
    assert (s.name, s.ref, s.highway, s.surface, s.oneway, s.maxspeed) == (
        "Via del Passo",
        "SP1",
        "tertiary",
        "asphalt",
        1,
        "50",
    )
    assert (s.start_node, s.end_node) == (1, 7) and s.score > 0 and len(s.corners) == 1
    assert by_way[11].score == 0.0 and by_way[11].corners == []
    assert by_way[12].score == 0.0 and by_way[12].corners == []
    assert (by_way[12].start_node, by_way[12].end_node, len(by_way[12].coords)) == (11, 12, 2)
    assert [a.kind for a in anomalies] == ["too_short"] and anomalies[0].id == "way/15"


def test_build_writes_segments_and_corners(ctx, tmp_path, monkeypatch):
    fixture = roads_pbf(tmp_path)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    seen = stub_tags_filter(monkeypatch)
    result = run_step(CurvatureStep(), ctx)
    assert result.status == "built", result.error
    assert seen["expressions"] == ["w/highway=" + ",".join(ctx.config.curvature.highways)]
    assert result.command == []
    assert result.outputs[0].rows == {"segments": 3, "corners": 1}
    conn = open_readonly(ctx.out_dir / "test-curvature.sqlite")
    seg = conn.execute(
        "SELECT id, osm_way_id, start_node, end_node, score, geometry FROM segments "
        "WHERE osm_way_id = 10"
    ).fetchone()
    assert seg[2:4] == (1, 7) and seg[4] > 0 and len(decode_polyline(seg[5])) == 7
    corner = conn.execute(
        "SELECT segment_id, ordinal, direction, min_radius_m, entry_m, apex_m, exit_m FROM corners"
    ).fetchone()
    assert corner[:3] == (seg[0], 0, "left") and 45 < corner[3] < 55
    assert corner[4] < corner[5] < corner[6]
    bbox = conn.execute(
        "SELECT min_lon, min_lat, max_lon, max_lat FROM segments WHERE id = ?", (seg[0],)
    ).fetchone()
    assert bbox == pytest.approx(bbox_of(decode_polyline(seg[5])), abs=1e-6)
    apex = conn.execute("SELECT apex_lon, apex_lat FROM corners").fetchone()
    interior = decode_polyline(seg[5])[1:-1]
    assert any(apex == pytest.approx(vertex, abs=1e-6) for vertex in interior)
    box = conn.execute("SELECT min_lon, max_lon, min_lat, max_lat FROM corners_rtree").fetchone()
    assert box == pytest.approx((apex[0], apex[0], apex[1], apex[1]), abs=1e-4)
    straight = conn.execute(
        "SELECT osm_way_id, score, length_m, geometry FROM segments "
        "WHERE osm_way_id IN (11, 12) ORDER BY osm_way_id"
    ).fetchall()
    assert [(row[0], row[1], len(decode_polyline(row[3]))) for row in straight] == [
        (11, 0.0, 3),
        (12, 0.0, 2),
    ]
    assert [round(row[2]) for row in straight] == [100, 50]
    assert conn.execute("SELECT count(*) FROM segments_rtree").fetchone() == (3,)
    assert conn.execute("SELECT count(*) FROM corners_rtree").fetchone() == (1,)
    assert conn.execute("SELECT region, layer, osm_timestamp FROM metadata").fetchone() == (
        "test",
        "curvature",
        "2026-10-06T20:21:06Z",
    )
    assert [a.kind for a in result.anomalies] == ["too_short"]


def test_outputs_and_expectation(ctx):
    step = CurvatureStep()
    (sqlite,) = step.outputs(ctx)
    assert sqlite == ctx.dist / "test" / "test-curvature.sqlite"
    e = step.expectation(ctx, sqlite)
    assert e.layer == "curvature" and e.region == "test" and e.row_ranges == {}
    assert e.count_tables == ("segments", "corners")
    expect = {"curvature_segments": RowRange(1, 10)}
    region = dataclasses.replace(ctx.config.region("test"), expect=expect)
    ctx2 = BuildContext(
        config=ctx.config, dist=ctx.dist, cache=ctx.cache, force=False, region=region
    )
    e2 = step.expectation(ctx2, sqlite)
    assert e2.row_ranges == {"segments": RowRange(1, 10)}
