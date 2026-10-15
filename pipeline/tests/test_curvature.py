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


def test_a_coincident_tail_is_merged():
    # a way ending on a duplicate of its previous vertex: the duplicate interior vertex goes,
    # the end node stays; coincident vertices have no circle (no division by zero)
    coords = [*east(3), east(3)[-1]]
    assert vertex_radii(coords) == [(math.inf, 0), (math.inf, 0)]
    merged, score, corners = score_way(coords)
    assert merged == east(3) and score == 0.0 and corners == []


def test_a_short_offset_tail_makes_no_corner():
    # the way ends 2 m past its last vertex and 1 m off the line, as junction nodes often do;
    # unmerged, that vertex would be a 58 m left corner
    coords = [*east(4), at(152, 1)]
    merged, score, corners = score_way(coords)
    assert merged == [*east(3), at(152, 1)] and score == 0.0 and corners == []


def test_end_jitter_is_merged_back_to_the_last_distant_vertex():
    # dropping only the second-to-last vertex would leave (0,0) (50,0) (52,1): a 58 m corner
    coords = [at(0, 0), at(50, 0), at(56, 1), at(52, 1)]
    merged, score, corners = score_way(coords)
    assert merged == [coords[0], coords[-1]] and score == 0.0 and corners == []


def test_vertex_radii_on_an_arc():
    coords = arc(50.0, 180, 270, 6)
    radii = vertex_radii(coords)
    assert len(radii) == len(coords) - 2
    assert all(r == pytest.approx(50.0, rel=0.02) and sign == 1 for r, sign in radii)


def test_arc_scores_in_band_3_and_yields_one_left_corner():
    coords = arc(50.0, 180, 270, 6)  # quarter circle, ~78.5 m
    merged, score, corners = score_way(coords)
    length = line_length_m(merged)
    # every interior vertex is band 3 and weighs half of each adjacent segment, so only half
    # of the first and half of the last segment go unweighted
    first, last = line_length_m(merged[:2]), line_length_m(merged[-2:])
    expected = 3 * (length - (first + last) / 2)
    assert score == pytest.approx(expected, rel=0.01)
    (corner,) = corners
    assert corner.direction == "left" and corner.min_radius_m == pytest.approx(50.0, rel=0.05)
    assert corner.entry_m < corner.apex_m < corner.exit_m <= length
    assert corner.entry_m == 0.0 and corner.exit_m == pytest.approx(length)


def s_curve():
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
    return left + right


def test_s_curve_yields_two_opposite_corners():
    _, score, corners = score_way(s_curve())
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


def test_way_score_weighs_half_of_each_adjacent_segment():
    coords = [at(0, 0), at(10, 0), at(40, 0)]
    assert way_score(coords, [(20.0, 1)]) == pytest.approx(4 * (10 + 30) / 2, rel=0.01)


def test_score_does_not_depend_on_the_drawing_direction():
    hook = [at(0, 0), at(10, 0), at(20, 10), at(200, 10)]  # 15.8 m (band 4), then 134.5 m (band 1)
    for coords in (hook, arc(50.0, 180, 270, 6), s_curve()):
        assert score_way(coords)[1] == pytest.approx(score_way(coords[::-1])[1])
    diagonal = math.hypot(10, 10)
    expected = 4 * (10 + diagonal) / 2 + 1 * (diagonal + 180) / 2  # 145.4 m
    assert score_way(hook)[1] == pytest.approx(expected, rel=0.01)
