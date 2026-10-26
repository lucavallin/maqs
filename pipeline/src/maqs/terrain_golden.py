"""Golden values for the Swift terrain tests, from the pipeline's reader and sampler.

`python -m maqs.terrain_golden ARCHIVE OUT` writes tile ids, tile digests and sampled elevations
for one terrain archive. The Swift PMTiles reader and sampler are tested against this file, so a
disagreement between the two implementations fails a test instead of shipping.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from maqs.osm.terrain_sampler import TerrainSampler, lonlat_to_pixel
from maqs.pmtiles_reader import PMTilesArchive, zxy_to_tile_id

GOLDEN_VERSION = 1
GRID = 25
TILE_ID_CASES = [
    (0, 0, 0),
    (1, 0, 0),
    (1, 1, 1),
    (5, 17, 11),
    (12, 2187, 1455),
    (12, 4095, 4095),
    (26, 67108863, 0),
]


def build_golden(archive: Path) -> dict[str, object]:
    """Golden values for the terrain archive at `archive`."""
    reader = PMTilesArchive(archive)
    sampler = TerrainSampler(archive)
    header = reader.header
    west, south, east, north = header.bbox

    points: list[dict[str, object]] = []
    for row in range(GRID):
        lat = north + (south - north) * row / (GRID - 1)
        for column in range(GRID):
            lon = west + (east - west) * column / (GRID - 1)
            points.append({"lon": lon, "lat": lat, "elevation": sampler.elevation(lon, lat)})

    tiles: list[dict[str, object]] = []
    for zoom in range(header.min_zoom, header.max_zoom + 1):
        x_min, y_min, _, _ = lonlat_to_pixel(west, north, zoom, 1)
        x_max, y_max, _, _ = lonlat_to_pixel(east, south, zoom, 1)
        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                raw = reader.tile(zoom, x, y)
                if raw is not None:
                    digest = hashlib.sha256(raw).hexdigest()
                    tiles.append({"z": zoom, "x": x, "y": y, "sha256": digest})

    return {
        "golden_version": GOLDEN_VERSION,
        "archive": archive.name,
        "zoom": header.max_zoom,
        "tile_ids": [
            {"z": z, "x": x, "y": y, "id": zxy_to_tile_id(z, x, y)} for z, x, y in TILE_ID_CASES
        ],
        "tiles": tiles,
        "points": points,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write golden terrain values as JSON.")
    parser.add_argument("archive", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args(argv)
    golden = build_golden(args.archive)
    args.out.write_text(json.dumps(golden, sort_keys=True, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
