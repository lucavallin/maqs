"""Golden values for the Swift MaqsData tests, from the pipeline's curvature code.

`python -m maqs.data_golden CURVATURE OUT` writes, for every segment of the curvature fixture and
for a few hand-built tracks, the merged geometry, length, score and corners that `score_way`
computes. The Swift corner analysis is tested against this file, so a disagreement between the two
implementations fails a test instead of shipping.
"""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
from pathlib import Path

from maqs.curvature.score import score_way
from maqs.geometry import (
    M_PER_DEG_LAT,
    M_PER_DEG_LON_EQUATOR,
    Coord,
    decode_polyline,
    line_length_m,
)

GOLDEN_VERSION = 1
ORIGIN: Coord = (12.25, 46.1)


def _local(points: list[tuple[float, float]]) -> list[Coord]:
    """Metres east and north of ORIGIN as lon/lat."""
    m_per_deg_lon = M_PER_DEG_LON_EQUATOR * math.cos(math.radians(ORIGIN[1]))
    return [(ORIGIN[0] + x / m_per_deg_lon, ORIGIN[1] + y / M_PER_DEG_LAT) for x, y in points]


def _arc(
    center: tuple[float, float], radius: float, start_deg: float, step_deg: float, count: int
) -> list[tuple[float, float]]:
    angles = (math.radians(start_deg + i * step_deg) for i in range(count))
    return [(center[0] + radius * math.cos(a), center[1] + radius * math.sin(a)) for a in angles]


def tracks() -> dict[str, list[Coord]]:
    """The hand-built tracks, by name: a closed circle, an S, a straight, and degenerate inputs."""
    return {
        "circle-40m": _local(_arc((0, 0), 40, 0, 10, 37)),
        "s-bend": _local(_arc((0, 50), 50, -90, 10, 10) + _arc((100, 50), 50, 180, -10, 10)),
        "straight": _local([(50.0 * i, 0.0) for i in range(10)]),
        "close-points": _local(_arc((0, 0), 100, 0, math.degrees(2 / 100), 20)),
        "two-points": _local([(0.0, 0.0), (50.0, 0.0)]),
        "ring-20m": _local(_arc((0, 0), 20, 0, 45, 9)),
    }


def analyse(coordinates: list[Coord]) -> dict[str, object]:
    """The merged geometry, its length, score and corners, as `score_way` computes them."""
    merged, score, corners = score_way(coordinates)
    return {
        "merged": [list(c) for c in merged],
        "length_m": line_length_m(merged),
        "score": score,
        "corners": [
            {
                "ordinal": ordinal,
                "apex": list(corner.apex),
                "min_radius_m": corner.min_radius_m,
                "direction": corner.direction,
                "entry_m": corner.entry_m,
                "apex_m": corner.apex_m,
                "exit_m": corner.exit_m,
            }
            for ordinal, corner in enumerate(corners)
        ],
    }


def build_golden(curvature: Path) -> dict[str, object]:
    """Golden values for the curvature file at `curvature` and for the built-in tracks."""
    conn = sqlite3.connect(f"file:{curvature}?mode=ro", uri=True)
    try:
        rows = conn.execute("SELECT osm_way_id, geometry FROM segments ORDER BY id").fetchall()
    finally:
        conn.close()
    segments = []
    for osm_way_id, geometry in rows:
        coordinates = decode_polyline(geometry)
        segments.append(
            {
                "osm_way_id": osm_way_id,
                "geometry": geometry,
                "coordinates": [list(c) for c in coordinates],
                "analysis": analyse(coordinates),
            }
        )
    return {
        "golden_version": GOLDEN_VERSION,
        "fixture": curvature.name,
        "segments": segments,
        "tracks": [
            {"name": name, "input": [list(c) for c in points], "analysis": analyse(points)}
            for name, points in tracks().items()
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write golden curvature values as JSON.")
    parser.add_argument("curvature", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args(argv)
    golden = build_golden(args.curvature)
    args.out.write_text(json.dumps(golden, sort_keys=True, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
