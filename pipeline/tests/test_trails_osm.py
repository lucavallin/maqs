import pytest

from maqs.steps.base import Anomaly
from maqs.trails.sources.osm import (
    OSM_LICENCE,
    WayGeom,
    assemble,
    normalise_difficulty,
    normalise_operator,
    read_osm_trails,
)
from tests.osm_fixtures import write_osm

P = {
    1: (12.250, 46.100),
    2: (12.251, 46.101),
    3: (12.252, 46.102),
    4: (12.253, 46.103),
    5: (12.260, 46.110),
    6: (12.270, 46.120),
    7: (12.271, 46.121),
}


def way(wid, nodes, **tags):
    return WayGeom(wid, nodes, [P[n] for n in nodes], tags)


def test_assemble_orders_and_reverses_ways():
    ways = {10: way(10, [1, 2, 3]), 11: way(11, [4, 3]), 12: way(12, [5, 4])}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered" and len(legs) == 1
    assert legs[0] == [P[1], P[2], P[3], P[4], P[5]]
    assert [a.kind for a in anomalies] == ["reversed", "reversed"]
    assert anomalies[0].id == "way/11"


def test_assemble_orients_by_member_order_when_first_way_is_stored_backwards():
    ways = {10: way(10, [3, 2, 1]), 11: way(11, [3, 4]), 12: way(12, [4, 5])}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered" and legs == [[P[1], P[2], P[3], P[4], P[5]]]
    assert [(a.kind, a.id) for a in anomalies] == [("reversed", "way/10")]


@pytest.mark.parametrize("closing", [[5, 6, 1], [5, 6, 3]], ids=["loop", "lollipop"])
def test_assemble_flips_a_backwards_first_way_on_loops_and_lollipops(closing):
    ways = {10: way(10, [3, 2, 1]), 11: way(11, [3, 4, 5]), 12: way(12, closing)}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered"
    assert legs == [[P[n] for n in [1, 2, 3, 4, 5, 6, closing[-1]]]]
    assert [(a.kind, a.id) for a in anomalies] == [("reversed", "way/10")]


@pytest.mark.parametrize(
    "stored, flagged",
    [
        ({10: [3, 2, 1], 11: [4, 3], 12: [4, 5]}, ["way/10", "way/11"]),
        ({10: [3, 2, 1], 11: [4, 3], 12: [5, 4]}, ["way/10", "way/11", "way/12"]),
    ],
    ids=["first-two-backwards", "all-backwards"],
)
def test_assemble_follows_member_order_whatever_the_stored_directions(stored, flagged):
    ways = {wid: way(wid, nodes) for wid, nodes in stored.items()}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered" and legs == [[P[1], P[2], P[3], P[4], P[5]]]
    assert [(a.kind, a.id) for a in anomalies] == [("reversed", wid) for wid in flagged]


@pytest.mark.parametrize(
    "stored, flagged",
    [
        ({10: [1, 2, 3], 11: [3, 4, 5], 12: [5, 6, 1]}, []),
        ({10: [3, 2, 1], 11: [5, 4, 3], 12: [5, 6, 1]}, ["way/10", "way/11"]),
        ({10: [3, 2, 1], 11: [5, 4, 3], 12: [1, 6, 5]}, ["way/10", "way/11", "way/12"]),
    ],
    ids=["all-forward", "first-two-backwards", "all-backwards"],
)
def test_assemble_walks_a_loop_from_its_first_member_in_member_order(stored, flagged):
    ways = {wid: way(wid, nodes) for wid, nodes in stored.items()}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered" and legs == [[P[n] for n in [1, 2, 3, 4, 5, 6, 1]]]
    assert [(a.kind, a.id) for a in anomalies] == [("reversed", wid) for wid in flagged]


def test_assemble_keeps_a_single_way_leg_as_stored():
    legs, status, anomalies = assemble([(10, "")], {10: way(10, [3, 2, 1])})
    assert status == "ordered" and legs == [[P[3], P[2], P[1]]] and anomalies == []


def test_assemble_prepends_when_a_way_joins_the_start():
    # Member order is 10 then 11, so the route walks 10 first: 5 -> 3, then 11 down to 1.
    ways = {10: way(10, [3, 4, 5]), 11: way(11, [1, 2, 3])}
    legs, status, anomalies = assemble([(10, ""), (11, "")], ways)
    assert status == "ordered" and legs == [[P[5], P[4], P[3], P[2], P[1]]]
    assert [(a.kind, a.id) for a in anomalies] == [("reversed", "way/10"), ("reversed", "way/11")]


def test_assemble_reports_gaps_with_distance():
    ways = {10: way(10, [1, 2]), 11: way(11, [6, 7])}
    legs, status, anomalies = assemble([(10, ""), (11, "")], ways)
    assert status == "gaps" and len(legs) == 2
    (gap,) = [a for a in anomalies if a.kind == "gap"]
    assert gap.id == "way/11" and "gap of 2" in gap.message  # ~2.6 km
    assert gap.message.endswith("before this way")


def test_assemble_flags_missing_member_but_keeps_the_rest():
    ways = {10: way(10, [1, 2, 3])}
    legs, status, anomalies = assemble([(10, ""), (99, "")], ways)
    assert status == "incomplete" and legs == [[P[1], P[2], P[3]]]
    assert Anomaly("missing_member", "way/99", "member way not in the extract") in anomalies


def test_assemble_flags_special_roles_but_keeps_them():
    ways = {10: way(10, [1, 2, 3]), 11: way(11, [3, 4])}
    legs, status, anomalies = assemble([(10, ""), (11, "alternative")], ways)
    assert status == "ordered" and legs[0][-1] == P[4]
    expected = Anomaly("role", "way/11", "member role 'alternative' kept in the main geometry")
    assert expected in anomalies


def test_assemble_with_no_usable_ways():
    legs, status, anomalies = assemble([(99, "")], {})
    assert legs == [] and status == "incomplete" and anomalies[0].kind == "missing_member"


@pytest.mark.parametrize(
    "cai, sac, way_sacs, expected",
    [
        ("E", None, [], (2, "cai_scale", "E", None)),
        ("eea:pd", None, [], (5, "cai_scale", "eea:pd", None)),
        ("EEA:ED", "hiking", [], (6, "cai_scale", "EEA:ED", None)),
        (
            None,
            "demanding_mountain_hiking",
            [],
            (3, "sac_scale", "demanding_mountain_hiking", None),
        ),
        (
            None,
            None,
            ["hiking", "alpine_hiking", "mountain_hiking"],
            (4, "sac_scale:ways", "alpine_hiking", None),
        ),
        (None, None, [], (None, None, None, None)),
        ("X", None, [], (None, "cai_scale", "X", "unknown cai_scale 'X'")),
        (None, "strolling", [], (None, "sac_scale", "strolling", "unknown sac_scale 'strolling'")),
    ],
)
def test_normalise_difficulty(cai, sac, way_sacs, expected):
    assert normalise_difficulty(cai, sac, way_sacs) == expected


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("Alpenverein Südtirol", "Alpenverein Südtirol"),
        ("AVS", "Alpenverein Südtirol"),
        ("alpenverein suedtirol", "Alpenverein Südtirol"),
        ("Alpenverein Sudtirol - Sektion Bozen", "Alpenverein Südtirol"),
        ("  CAI Belluno ", "CAI Belluno"),
        (None, None),
    ],
)
def test_normalise_operator(raw, expected):
    assert normalise_operator(raw) == expected


@pytest.fixture
def hiking_pbf(tmp_path):
    nodes = {1: P[1], 2: P[2], 3: P[3], 4: P[4], 5: P[5], 6: P[6], 7: P[7]}
    ways = {
        10: ([1, 2, 3], {"highway": "path", "sac_scale": "mountain_hiking"}),
        11: ([4, 3], {"highway": "path", "sac_scale": "alpine_hiking"}),
        12: ([5, 4], {"highway": "path"}),
        20: ([6, 7], {"highway": "path"}),
        30: ([1, 2], {"highway": "track"}),
    }
    full_tags = {
        "type": "route",
        "route": "hiking",
        "ref": "501",
        "ref:REI": "VE501",
        "name": "Alta Via",
        "cai_scale": "E",
        "network": "lwn",
        "operator": "avs",
        "osmc:symbol": "red:white:red_bar",
        "from": "Nevegal",
        "to": "Col Visentin",
        "roundtrip": "no",
        "survey:date": "2025-06-01",
        "website": "https://example.org",
    }
    relations = {
        100: ([("w", 10, ""), ("w", 11, ""), ("w", 12, "")], full_tags),
        # way 99 is missing from the extract
        101: ([("w", 20, ""), ("w", 99, "")], {"type": "route", "route": "hiking", "ref": "502"}),
        # no scale on the relation: difficulty comes from the ways
        102: ([("w", 10, ""), ("w", 11, "")], {"type": "route", "route": "hiking", "name": "No"}),
        # superroute: only relation members
        103: ([("r", 100, "")], {"type": "route", "route": "hiking", "name": "Super"}),
        200: ([("w", 30, "")], {"type": "route", "route": "bicycle", "ref": "B1"}),  # ignored
    }
    return write_osm(tmp_path / "hiking.osm.pbf", nodes, ways, relations)


def test_read_osm_trails_maps_tags_and_geometry(hiking_pbf):
    source_date = "2026-10-06T20:21:06Z"
    records = {r.osm_id: r for r in read_osm_trails(hiking_pbf, source_date=source_date)}
    assert set(records) == {100, 101, 102, 103}
    r = records[100]
    identity = (r.source, r.source_id, r.source_licence, r.source_date, r.osm_type)
    assert identity == ("osm", "relation/100", OSM_LICENCE, source_date, "relation")
    assert (r.ref, r.ref_rei, r.name, r.network, r.osmc_symbol) == (
        "501",
        "VE501",
        "Alta Via",
        "lwn",
        "red:white:red_bar",
    )
    assert (r.difficulty, r.difficulty_scheme, r.difficulty_value) == (2, "cai_scale", "E")
    assert r.operator == "Alpenverein Südtirol"
    assert (r.from_name, r.to_name, r.roundtrip, r.survey_date, r.website) == (
        "Nevegal",
        "Col Visentin",
        0,
        "2025-06-01",
        "https://example.org",
    )
    assert r.geometry_status == "ordered"
    assert r.legs == [[P[1], P[2], P[3], P[4], P[5]]]
    assert r.length_m == pytest.approx(1353, abs=20)
    assert r.bbox == (12.25, 46.1, 12.26, 46.11)
    assert records[103].geometry_status == "incomplete" and records[103].legs == []
    assert sorted(records[103].anomalies, key=lambda a: a.kind) == [
        Anomaly("no_geometry", "relation/103", "relation has no way members in the extract"),
        Anomaly("relation_member", "relation/103", "relation members ignored (superroute): 1"),
    ]
    assert records[101].geometry_status == "incomplete"
    assert records[101].legs == [[P[6], P[7]]]
    assert any(a.kind == "missing_member" and a.id == "way/99" for a in records[101].anomalies)
    fallback = records[102]
    assert (fallback.difficulty, fallback.difficulty_scheme, fallback.difficulty_value) == (
        4,
        "sac_scale:ways",
        "alpine_hiking",
    )
    assert fallback.roundtrip is None and fallback.ref is None


def test_read_osm_trails_reports_one_reversed_anomaly_per_relation(hiking_pbf):
    records = {r.osm_id: r for r in read_osm_trails(hiking_pbf, source_date=None)}
    reversed_by_relation = {
        rid: [a for a in r.anomalies if a.kind == "reversed"] for rid, r in records.items()
    }
    assert reversed_by_relation[100] == [
        Anomaly("reversed", "relation/100", "2 of 3 member ways reversed")
    ]
    assert reversed_by_relation[102] == [
        Anomaly("reversed", "relation/102", "1 of 2 member ways reversed")
    ]
    assert reversed_by_relation[101] == [] and reversed_by_relation[103] == []
