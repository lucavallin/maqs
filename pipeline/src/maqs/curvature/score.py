"""Road curvature: per-vertex radius, per-way score, discrete corners (ADR 0005, 0008, 0011).

The normative description is in docs/data-format.md; the Swift package mirrors these rules so
recorded tracks and road corners agree by construction.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

from maqs.geometry import Coord, circumradius, cumulative_m, merge_close

# (radius upper bound in metres, exclusive; weight): the bands the curvature project uses
BANDS: tuple[tuple[float, int], ...] = ((30.0, 4), (60.0, 3), (100.0, 2), (175.0, 1))
CORNER_MAX_RADIUS_M = 500.0
MERGE_MIN_M = 5.0


def band_weight(radius_m: float) -> int:
    """The score weight of a vertex radius: 4 under 30 m down to 0 from 175 m (and straight)."""
    for limit, weight in BANDS:
        if radius_m < limit:
            return weight
    return 0


def vertex_radii(coords: Sequence[Coord]) -> list[tuple[float, int]]:
    """(radius, turn sign) at each interior vertex 1..n-2; collinear or coincident is (inf, 0)."""
    return [
        circumradius(coords[i - 1], coords[i], coords[i + 1]) for i in range(1, len(coords) - 1)
    ]


def way_score(coords: Sequence[Coord], radii: Sequence[tuple[float, int]]) -> float:
    """Sum of segment length × the band weight of the segment's start vertex.

    The first segment starts at the way's first node, which has no radius, so it weighs 0.
    """
    distances = cumulative_m(coords)
    score = 0.0
    for i, (radius, _) in enumerate(radii, start=1):  # radius at vertex i weighs segment i -> i+1
        score += (distances[i + 1] - distances[i]) * band_weight(radius)
    return score


@dataclass(frozen=True)
class Corner:
    """One discrete curve: a maximal run of same-direction vertices tighter than the cutoff."""

    apex_index: int
    apex: Coord
    min_radius_m: float
    direction: str
    entry_m: float
    apex_m: float
    exit_m: float


def find_corners(coords: Sequence[Coord], radii: Sequence[tuple[float, int]]) -> list[Corner]:
    """Corners along the way, in order.

    A corner is a maximal run of consecutive interior vertices with the same turn sign and a
    radius under CORNER_MAX_RADIUS_M. Its apex is the run's tightest vertex; entry and exit are
    the vertices just before and after the run; `min_radius_m` is the circle through entry, apex
    and exit; distances are metres along the way from its first node.
    """
    distances = cumulative_m(coords)
    corners: list[Corner] = []
    run: list[int] = []  # interior vertex indices of the current run

    def close_run() -> None:
        if not run:
            return
        apex = min(run, key=lambda i: radii[i - 1][0])
        entry, exit_ = run[0] - 1, run[-1] + 1
        radius, _ = circumradius(coords[entry], coords[apex], coords[exit_])
        if math.isinf(radius):
            radius = radii[apex - 1][0]
        direction = "left" if radii[apex - 1][1] > 0 else "right"
        corners.append(
            Corner(
                apex,
                coords[apex],
                radius,
                direction,
                distances[entry],
                distances[apex],
                distances[exit_],
            )
        )
        run.clear()

    for i, (radius, sign) in enumerate(radii, start=1):
        turning = sign != 0 and radius < CORNER_MAX_RADIUS_M
        if turning and (not run or radii[run[-1] - 1][1] == sign):
            run.append(i)
            continue
        close_run()
        if turning:
            run.append(i)
    close_run()
    return corners


def score_way(coords: Sequence[Coord]) -> tuple[list[Coord], float, list[Corner]]:
    """Merge vertices closer than MERGE_MIN_M, then score the way and find its corners.

    Returns the merged coordinates, which the score, the corner distances and the stored
    geometry all refer to. Fewer than three merged vertices have no interior: score 0, no corners.
    """
    merged = merge_close(coords, MERGE_MIN_M)
    if len(merged) < 3:
        return merged, 0.0, []
    radii = vertex_radii(merged)
    return merged, way_score(merged, radii), find_corners(merged, radii)
