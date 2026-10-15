import math

import pytest

from maqs.curvature.score import (
    BANDS,
    CORNER_MAX_RADIUS_M,
    band_weight,
    score_way,
    vertex_radii,
    way_score,
)
from maqs.geometry import line_length_m

CX, CY = 12.25, 46.10
M_PER_DEG_LON = 111_320 * math.cos(math.radians(CY))
M_PER_DEG_LAT = 110_574


def at(x_m, y_m):
    """The point x_m metres east and y_m metres north of (CX, CY)."""
    return (CX + x_m / M_PER_DEG_LON, CY + y_m / M_PER_DEG_LAT)


def arc(radius_m, start_deg, end_deg, steps):
    """Counter-clockwise arc around (CX, CY) sampled every (end-start)/steps degrees."""
    out = []
    for i in range(steps + 1):
        a = math.radians(start_deg + (end_deg - start_deg) * i / steps)
        out.append(at(radius_m * math.cos(a), radius_m * math.sin(a)))
    return out


def east(n, spacing_m=50.0):
    return [at(i * spacing_m, 0.0) for i in range(n)]


def test_band_weights():
    radii = (10, 29.9, 30, 59, 60, 99, 100, 174, 175, 1000, math.inf)
    assert [band_weight(r) for r in radii] == [4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0]
    assert BANDS == ((30.0, 4), (60.0, 3), (100.0, 2), (175.0, 1))


def test_straight_roads_score_zero_with_no_corners():
    # two nodes, three collinear nodes, ten collinear nodes: no division by zero anywhere
    for coords in (east(2), east(3), east(10)):
        merged, score, corners = score_way(coords)
        assert score == 0.0 and corners == [] and merged == coords


def test_coincident_tail_scores_without_error():
    # the 5 m merge always keeps the last vertex, so a way can end on a duplicate of its
    # second-to-last vertex
    coords = [*east(3), east(3)[-1]]
    merged, score, corners = score_way(coords)
    assert merged == coords and score == 0.0 and corners == []
    assert vertex_radii(merged) == [(math.inf, 0), (math.inf, 0)]


def test_vertex_radii_on_an_arc():
    coords = arc(50.0, 180, 270, 6)
    radii = vertex_radii(coords)
    assert len(radii) == len(coords) - 2
    assert all(r == pytest.approx(50.0, rel=0.02) and sign == 1 for r, sign in radii)


def test_arc_scores_in_band_3_and_yields_one_left_corner():
    coords = arc(50.0, 180, 270, 6)  # quarter circle, ~78.5 m
    merged, score, corners = score_way(coords)
    length = line_length_m(merged)
    # the first segment has no vertex radius before it and weighs 0; the rest are band 3
    expected = 3 * (length - line_length_m(merged[:2]))
    assert score == pytest.approx(expected, rel=0.01)
    (corner,) = corners
    assert corner.direction == "left" and corner.min_radius_m == pytest.approx(50.0, rel=0.05)
    assert corner.entry_m < corner.apex_m < corner.exit_m <= length
    assert corner.entry_m == 0.0 and corner.exit_m == pytest.approx(length)


def test_s_curve_yields_two_opposite_corners():
    left = arc(60.0, 180, 270, 5)  # ends at the bottom of its circle, heading east
    # a right turn from there: a circle of the same radius centred 60 m south of the join point,
    # walked clockwise from its top (angle 90°) towards angle 0°
    cx, cy = left[-1][0], left[-1][1] - 60.0 / M_PER_DEG_LAT
    right = [
        (
            cx + 60.0 * math.cos(math.radians(a)) / M_PER_DEG_LON,
            cy + 60.0 * math.sin(math.radians(a)) / M_PER_DEG_LAT,
        )
        for a in (72, 54, 36, 18, 0)
    ]
    coords = left + right
    _, score, corners = score_way(coords)
    assert score > 0 and len(corners) == 2
    assert [c.direction for c in corners] == ["left", "right"]
    assert corners[0].exit_m <= corners[1].entry_m


def test_adjacent_opposite_turns_split_into_two_corners():
    # left at vertex 1, right at vertex 2 (both ~137 m): the segment between them is the exit of
    # the first corner and the entry of the second
    coords = [at(0, 0), at(50, 0), at(100, 20), at(150, 20)]
    merged, _, corners = score_way(coords)
    assert [(c.apex_index, c.direction) for c in corners] == [(1, "left"), (2, "right")]
    assert corners[0].exit_m == corners[1].apex_m and corners[1].entry_m == corners[0].apex_m
    assert all(c.min_radius_m == pytest.approx(137, rel=0.02) for c in corners)


def test_a_straight_vertex_between_two_left_bends_ends_the_corner():
    coords = [at(0, 0), at(50, 0), at(100, 10), at(150, 20), at(200, 40), at(250, 70)]
    _, _, corners = score_way(coords)
    assert [(c.apex_index, c.direction) for c in corners] == [(1, "left"), (3, "left")]
    assert corners[0].exit_m == corners[1].entry_m  # both at the straight vertex's neighbour
    assert corners[1].exit_m == pytest.approx(line_length_m(coords))


def test_gentle_bend_above_the_cutoff_is_not_a_corner():
    coords = arc(CORNER_MAX_RADIUS_M + 100, 180, 200, 8)
    _, score, corners = score_way(coords)
    assert corners == [] and score == 0.0


def test_jitter_is_merged_before_scoring():
    coords = east(5)
    jitter = at(51, 1)  # ~1.4 m from the second vertex
    merged, score, corners = score_way([*coords[:2], jitter, *coords[2:]])
    assert merged == coords and score == 0.0 and corners == []


def test_way_score_uses_the_start_vertex_radius():
    coords = east(3)
    assert way_score(coords, [(20.0, 1)]) == pytest.approx(4 * 50.0, rel=0.01)
