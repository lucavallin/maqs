"""Elevation along a line from the region's own terrarium terrain archive.

Tiles are 512 px WebP at the archive's max zoom (12). Sampling is bilinear inside a tile and
clamped at its edges (no cross-tile interpolation). Ascent and descent use a hysteresis so that
sensor-scale noise does not add up (ADR 0011).
"""

from __future__ import annotations

import io
import math
from collections import OrderedDict
from collections.abc import Sequence
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from maqs.geometry import Coord, resample
from maqs.pmtiles_header import PMTilesError
from maqs.pmtiles_reader import PMTilesArchive


def terrarium_to_m(r: int, g: int, b: int) -> float:
    return (r * 256 + g + b / 256) - 32768


def lonlat_to_pixel(
    lon: float, lat: float, zoom: int, tile_size: int
) -> tuple[int, int, float, float]:
    """Tile x, tile y and the pixel position inside that tile (Web Mercator)."""
    n = 1 << zoom
    x = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    y = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n
    tx, ty = math.floor(x), math.floor(y)
    return tx, ty, (x - tx) * tile_size, (y - ty) * tile_size


class TerrainSampler:
    def __init__(self, path: Path, *, max_tiles: int = 64) -> None:
        self.archive = PMTilesArchive(path)
        self.zoom = self.archive.header.max_zoom
        self._tiles: OrderedDict[tuple[int, int], Image.Image | None] = OrderedDict()
        self._max_tiles = max_tiles

    def _tile(self, tx: int, ty: int) -> Image.Image | None:
        key = (tx, ty)
        if key in self._tiles:
            self._tiles.move_to_end(key)
            return self._tiles[key]
        raw = self.archive.tile(self.zoom, tx, ty)
        image = self._decode(raw) if raw else None
        self._tiles[key] = image
        if len(self._tiles) > self._max_tiles:
            self._tiles.popitem(last=False)
        return image

    def _decode(self, raw: bytes) -> Image.Image:
        try:
            image = Image.open(io.BytesIO(raw)).convert("RGB")
        except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
            raise PMTilesError(
                f"{self.archive.path}: terrain tile is not a readable image"
            ) from exc
        if image.width != image.height:
            raise PMTilesError(f"{self.archive.path}: terrain tile is not square")
        return image

    def elevation(self, lon: float, lat: float) -> float | None:
        """Metres above sea level, or None where the archive has no tile."""
        if not (math.isfinite(lon) and math.isfinite(lat) and -85.05 < lat < 85.05):
            return None
        tx, ty, _, _ = lonlat_to_pixel(lon, lat, self.zoom, 1)
        if not (0 <= tx < 1 << self.zoom and 0 <= ty < 1 << self.zoom):
            return None
        image = self._tile(tx, ty)
        if image is None:
            return None
        size = image.width
        _, _, px, py = lonlat_to_pixel(lon, lat, self.zoom, size)
        px, py = min(max(px - 0.5, 0.0), size - 1.0), min(max(py - 0.5, 0.0), size - 1.0)
        x0, y0 = int(px), int(py)
        x1, y1 = min(x0 + 1, size - 1), min(y0 + 1, size - 1)
        fx, fy = px - x0, py - y0
        pixels = image.load()

        def e(x: int, y: int) -> float:
            return terrarium_to_m(*pixels[x, y][:3])

        top = e(x0, y0) * (1 - fx) + e(x1, y0) * fx
        bottom = e(x0, y1) * (1 - fx) + e(x1, y1) * fx
        return top * (1 - fy) + bottom * fy


def ascent_descent(
    sampler: TerrainSampler,
    coords: Sequence[Coord],
    *,
    step_m: float = 25.0,
    hysteresis_m: float = 5.0,
) -> tuple[float | None, float | None, int]:
    """Sum climbs and descents along the line; a move counts once it exceeds the hysteresis.

    Returns (ascent, descent, samples without a tile). When no sample has a tile the first two
    are None, so the caller can report missing coverage instead of a flat 0.
    """
    samples = [sampler.elevation(lon, lat) for lon, lat in resample(coords, step_m)]
    missing = sum(1 for s in samples if s is None)
    values = [s for s in samples if s is not None]
    if not values:
        return None, None, missing
    ascent = descent = 0.0
    base = values[0]
    for value in values[1:]:
        if value > base + hysteresis_m:
            ascent += value - base
            base = value
        elif value < base - hysteresis_m:
            descent += base - value
            base = value
    return ascent, descent, missing
