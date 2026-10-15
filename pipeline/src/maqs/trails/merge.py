"""Merge trail records from several sources by priority (ADR 0006).

A record with the same ref as a primary from a higher-priority source, whose geometry mostly
lies within overlap_m of it, becomes a secondary reference pointing at that winner. Records
from the same source are never deduplicated against each other. Today the only real source
is OSM; the seam is exercised with a synthetic second source in tests.
"""

from __future__ import annotations

from collections.abc import Sequence

from maqs.geometry import Coord, haversine_m, resample
from maqs.trails.model import TrailRecord


def normalise_ref(ref: str | None) -> str | None:
    """Collapse whitespace and case so `cai 501` and `CAI  501` compare equal."""
    if ref is None:
        return None
    text = " ".join(ref.split()).upper()
    return text or None


def _samples(legs: Sequence[Sequence[Coord]], step_m: float) -> list[Coord]:
    """Resample every leg separately so gaps between legs get no phantom points."""
    return [p for leg in legs if len(leg) >= 2 for p in resample(leg, step_m)]


def _share(
    candidate_legs: Sequence[Sequence[Coord]],
    winner_legs: Sequence[Sequence[Coord]],
    *,
    overlap_m: float,
    step_m: float,
) -> float:
    winner_points = _samples(winner_legs, step_m)
    points = _samples(candidate_legs, step_m)
    if not points or not winner_points:
        return 0.0
    tolerance = overlap_m + step_m / 2
    near = sum(1 for p in points if any(haversine_m(p, w) <= tolerance for w in winner_points))
    return near / len(points)


def overlap_share(
    candidate: Sequence[Coord],
    winner: Sequence[Coord],
    *,
    overlap_m: float,
    step_m: float,
) -> float:
    """Share of the candidate's resampled points lying near the winner.

    Both lines are resampled every step_m; a candidate point is near when it is within
    overlap_m + step_m / 2 of a winner sample point (vertex distance, not distance to the
    winner's line, hence the half-step allowance).
    """
    return _share([candidate], [winner], overlap_m=overlap_m, step_m=step_m)


def _find_winner(
    record: TrailRecord,
    candidates: Sequence[TrailRecord],
    *,
    overlap_m: float,
    min_share: float,
    step_m: float,
) -> int | None:
    """First candidate that the whole record (all legs, length-weighted) overlaps."""
    for index, winner in enumerate(candidates):
        share = _share(record.legs, winner.legs, overlap_m=overlap_m, step_m=step_m)
        if share > min_share:
            return index
    return None


def merge(
    sources: Sequence[tuple[str, list[TrailRecord]]],
    *,
    overlap_m: float = 50.0,
    min_share: float = 0.5,
    step_m: float = 25.0,
) -> list[TrailRecord]:
    """Return primaries in source-priority order, then secondaries.

    A secondary's `secondary_of` is the index of its winner in the returned list.
    """
    primaries: list[TrailRecord] = []
    secondaries: list[TrailRecord] = []
    # ref key -> (source position, index in primaries); primaries keep their final index.
    by_ref: dict[str, list[tuple[int, int]]] = {}
    for source_position, (_, records) in enumerate(sources):
        for record in records:
            key = normalise_ref(record.ref)
            winner_index = None
            if key is not None:
                higher = [
                    index for position, index in by_ref.get(key, []) if position < source_position
                ]
                found = _find_winner(
                    record,
                    [primaries[i] for i in higher],
                    overlap_m=overlap_m,
                    min_share=min_share,
                    step_m=step_m,
                )
                if found is not None:
                    winner_index = higher[found]
            if winner_index is None:
                primaries.append(record)
                if key is not None:
                    by_ref.setdefault(key, []).append((source_position, len(primaries) - 1))
            else:
                record.secondary_of = winner_index
                secondaries.append(record)
    return primaries + secondaries
