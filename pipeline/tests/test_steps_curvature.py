import dataclasses

import pytest

from maqs.config import CurvatureConfig, RowRange
from maqs.context import BuildContext
from maqs.curvature.step import CurvatureStep, junction_rows, parse_oneway, read_roads
from maqs.geometry import bbox_of, decode_polyline
from maqs.osm import extract
from maqs.sqlite_out import open_readonly
from maqs.steps.base import Anomaly, run_step
from tests.osm_fixtures import write_osm
from tests.step_fixtures import stub_tags_filter
from tests.test_curvature import arc, at, east


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


def test_read_roads_keeps_a_way_with_unlocated_nodes_and_reports_them(tmp_path):
    nodes = dict(enumerate(east(3), start=1))  # 1..3; nodes 500..502 are not in the file
    ways = {
        20: ([1, 500, 2, 3], {"highway": "primary"}),
        21: ([1, 501, 502], {"highway": "primary"}),  # one located node: too short, nothing else
    }
    pbf = write_osm(tmp_path / "gaps.osm.pbf", nodes, ways, {})
    segments, anomalies = read_roads(pbf, CurvatureConfig(("primary",), ()))
    assert [(s.osm_way_id, s.start_node, s.end_node, len(s.coords)) for s in segments] == [
        (20, 1, 3, 3)
    ]
    assert anomalies == [
        Anomaly("unlocated_nodes", "way/20", "1 of 4 nodes have no location"),
        Anomaly("too_short", "way/21", "1 located nodes; need 2"),
    ]


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
    assert result.outputs[0].rows == {"segments": 3, "corners": 1, "junctions": 0}
    conn = open_readonly(ctx.out_dir / "test-curvature.v1.sqlite")
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
    assert sqlite == ctx.dist / "test" / "test-curvature.v1.sqlite"
    e = step.expectation(ctx, sqlite)
    assert e.layer == "curvature" and e.region == "test" and e.row_ranges == {}
    assert e.count_tables == ("segments", "corners", "junctions")
    expect = {"curvature_segments": RowRange(1, 10)}
    region = dataclasses.replace(ctx.config.region("test"), expect=expect)
    ctx2 = BuildContext(
        config=ctx.config, dist=ctx.dist, cache=ctx.cache, force=False, region=region
    )
    e2 = step.expectation(ctx2, sqlite)
    assert e2.row_ranges == {"segments": RowRange(1, 10)}


PRIMARY = CurvatureConfig(("primary", "secondary", "residential"), ("gravel",))


def junction_network(tmp_path, ways):
    """Nodes 1..5 run east 50 m apart. Off node 3: 6 is 50 m north, 7 50 m south, 8 100 m north."""
    nodes = dict(enumerate(east(5), start=1))
    nodes[6] = at(100.0, 50.0)
    nodes[7] = at(100.0, -50.0)
    nodes[8] = at(100.0, 100.0)
    return write_osm(tmp_path / "junctions.osm.pbf", nodes, ways, {})


def rows_for(pbf, config=PRIMARY):
    segments, _ = read_roads(pbf, config)
    return segments, junction_rows(segments)


def test_a_t_junction_gives_one_row_on_the_through_way(tmp_path):
    ways = {1: ([1, 2, 3, 4, 5], {"highway": "primary"}), 2: ([3, 6], {"highway": "primary"})}
    segments, rows = rows_for(junction_network(tmp_path, ways))
    assert [s.osm_way_id for s in segments] == [1, 2]
    assert [(r[0], r[1]) for r in rows] == [(1, 3)]
    assert rows[0][2] == pytest.approx(100.0, abs=0.5)


def test_a_crossing_at_a_shared_node_gives_a_row_on_each_way(tmp_path):
    ways = {
        1: ([1, 2, 3, 4, 5], {"highway": "primary"}),
        3: ([7, 3, 8], {"highway": "primary"}),
    }
    _, rows = rows_for(junction_network(tmp_path, ways))
    assert [(r[0], r[1]) for r in rows] == [(1, 3), (2, 3)]
    assert rows[0][2] == pytest.approx(100.0, abs=0.5)
    assert rows[1][2] == pytest.approx(50.0, abs=0.5)


def test_a_ring_with_two_entries_gives_two_rows_on_the_ring(tmp_path):
    nodes = {
        10: at(0, 0),
        11: at(40, 0),
        12: at(40, 40),
        13: at(0, 40),
        20: at(120, 0),
        21: at(-80, 40),
    }
    ways = {
        1: ([10, 11, 12, 13, 10], {"highway": "primary", "junction": "roundabout"}),
        2: ([20, 11], {"highway": "primary"}),
        3: ([21, 13], {"highway": "primary"}),
    }
    pbf = write_osm(tmp_path / "ring.osm.pbf", nodes, ways, {})
    _, rows = rows_for(pbf)
    assert [(r[0], r[1]) for r in rows] == [(1, 11), (1, 13)]
    assert rows[0][2] == pytest.approx(40.0, abs=0.5)
    assert rows[1][2] == pytest.approx(120.0, abs=0.5)


def test_a_node_dropped_by_the_merge_keeps_its_position(tmp_path):
    nodes = {1: at(0, 0), 2: at(2, 0), 3: at(60, 0), 9: at(2, 50)}
    ways = {1: ([1, 2, 3], {"highway": "primary"}), 2: ([2, 9], {"highway": "primary"})}
    segments, rows = rows_for(write_osm(tmp_path / "dropped.osm.pbf", nodes, ways, {}))
    assert len(segments[0].coords) == 2
    assert [(r[0], r[1]) for r in rows] == [(1, 2)]
    assert rows[0][2] == pytest.approx(2.0, abs=0.1)


@pytest.mark.parametrize(
    "tags", [{"highway": "residential"}, {"highway": "primary", "surface": "gravel"}]
)
def test_a_node_shared_only_with_an_excluded_way_gives_no_row(tmp_path, tags):
    config = CurvatureConfig(("primary",), ("gravel",))
    ways = {1: ([1, 2, 3, 4, 5], {"highway": "primary"}), 2: ([3, 6], tags)}
    segments, rows = rows_for(junction_network(tmp_path, ways), config)
    assert [s.osm_way_id for s in segments] == [1]
    assert rows == []


def test_a_way_through_one_node_twice_gives_two_rows(tmp_path):
    nodes = {
        1: at(0, 0),
        2: at(100, 0),
        3: at(100, 100),
        4: at(200, 100),
        5: at(200, 0),
        9: at(100, -50),
    }
    ways = {
        1: ([1, 2, 3, 4, 5, 2, 3], {"highway": "primary"}),
        2: ([2, 9], {"highway": "primary"}),
    }
    _, rows = rows_for(write_osm(tmp_path / "twice.osm.pbf", nodes, ways, {}))
    on_loop = [r for r in rows if r[0] == 1 and r[1] == 2]
    assert len(on_loop) == 2
    assert on_loop[0][2] == pytest.approx(100.0, abs=0.5)
    assert on_loop[1][2] == pytest.approx(500.0, abs=1.0)


def test_the_junction_tag_is_stored(tmp_path):
    nodes = {1: at(0, 0), 2: at(100, 0), 3: at(100, 100)}
    ways = {
        1: ([1, 2], {"highway": "primary", "junction": "roundabout"}),
        2: ([2, 3], {"highway": "primary"}),
    }
    segments, _ = rows_for(write_osm(tmp_path / "tag.osm.pbf", nodes, ways, {}))
    assert [s.junction for s in segments] == ["roundabout", None]


def test_the_step_writes_the_junctions_table(ctx, tmp_path, monkeypatch):
    ways = {
        1: ([1, 2, 3, 4, 5], {"highway": "primary", "junction": "roundabout"}),
        2: ([3, 6], {"highway": "primary"}),
    }
    fixture = junction_network(tmp_path, ways)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    stub_tags_filter(monkeypatch)
    result = run_step(CurvatureStep(), ctx)
    assert result.status == "built", result.error
    assert result.outputs[0].rows["junctions"] == 1
    segments, _ = read_roads(fixture, ctx.config.curvature)
    expected = junction_rows(segments)
    conn = open_readonly(ctx.out_dir / "test-curvature.v1.sqlite")
    stored = conn.execute("SELECT segment_id, node, along_m FROM junctions").fetchall()
    assert stored == expected and stored[0][:2] == (1, 3)
    assert conn.execute("SELECT junction FROM segments ORDER BY id").fetchall() == [
        ("roundabout",),
        (None,),
    ]


def test_a_way_doubling_back_onto_a_passed_point_does_not_crash(tmp_path):
    # the merge's backward pass drops V, which equals the last vertex L; W (1 m from L) is shared
    nodes = {
        1: at(0, 0),
        2: at(100, 0),
        3: at(200, 0),
        4: at(199, 0),
        5: at(200, 0),
        9: at(199, 50),
    }
    ways = {1: ([1, 2, 3, 4, 5], {"highway": "primary"}), 2: ([4, 9], {"highway": "primary"})}
    segments, rows = rows_for(write_osm(tmp_path / "doubling.osm.pbf", nodes, ways, {}))
    assert len(segments[0].coords) == 3
    assert [(r[0], r[1]) for r in rows] == [(1, 4)]
    assert rows[0][2] == pytest.approx(200.0, abs=1.5)
