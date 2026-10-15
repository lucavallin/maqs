"""Coordinate maths shared by every data layer: polyline6, distances, resampling, circles.

Coordinates are (lon, lat) in WGS 84 degrees everywhere. Distances are metres.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence

Coord = tuple[float, float]

EARTH_RADIUS_M = 6_371_008.8
M_PER_DEG_LAT = 110_574.0
M_PER_DEG_LON_EQUATOR = 111_320.0


def _encode_value(value: int) -> str:
    value = ~(value << 1) if value < 0 else value << 1
    out = []
    while value >= 0x20:
        out.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    out.append(chr(value + 63))
    return "".join(out)


def encode_polyline(coords: Sequence[Coord], precision: int = 6) -> str:
    factor = 10**precision
    out: list[str] = []
    last_lat = last_lon = 0
    for lon, lat in coords:
        ilat, ilon = round(lat * factor), round(lon * factor)
        out.append(_encode_value(ilat - last_lat))
        out.append(_encode_value(ilon - last_lon))
        last_lat, last_lon = ilat, ilon
    return "".join(out)


def decode_polyline(text: str, precision: int = 6) -> list[Coord]:
    factor = 10**precision
    coords: list[Coord] = []
    index = lat = lon = 0
    while index < len(text):
        values = []
        for _ in range(2):
            result = shift = 0
            while True:
                if index >= len(text):
                    raise ValueError("truncated polyline")
                byte = ord(text[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            values.append(~(result >> 1) if result & 1 else result >> 1)
        lat += values[0]
        lon += values[1]
        coords.append((lon / factor, lat / factor))
    return coords


def haversine_m(a: Coord, b: Coord) -> float:
    lon1, lat1 = map(math.radians, a)
    lon2, lat2 = map(math.radians, b)
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def cumulative_m(coords: Sequence[Coord]) -> list[float]:
    out = [0.0]
    for p, q in zip(coords, coords[1:], strict=False):
        out.append(out[-1] + haversine_m(p, q))
    return out


def line_length_m(coords: Sequence[Coord]) -> float:
    return cumulative_m(coords)[-1] if coords else 0.0


def bbox_of(coords: Iterable[Coord]) -> tuple[float, float, float, float]:
    lons, lats = zip(*coords, strict=True)
    return (min(lons), min(lats), max(lons), max(lats))


def resample(coords: Sequence[Coord], step_m: float) -> list[Coord]:
    """Points every step_m along the line, plus the exact endpoints."""
    if len(coords) < 2:
        return list(coords)
    out: list[Coord] = [coords[0]]
    carry = 0.0  # distance already covered since the last emitted point
    for p, q in zip(coords, coords[1:], strict=False):
        seg = haversine_m(p, q)
        if seg == 0.0:
            continue
        pos = step_m - carry
        while pos < seg:
            t = pos / seg
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
            pos += step_m
        carry = seg - (pos - step_m)
    if out[-1] != coords[-1]:
        out.append(coords[-1])
    return out


def _local_xy(origin: Coord, p: Coord) -> tuple[float, float]:
    m_per_deg_lon = M_PER_DEG_LON_EQUATOR * math.cos(math.radians(origin[1]))
    return ((p[0] - origin[0]) * m_per_deg_lon, (p[1] - origin[1]) * M_PER_DEG_LAT)


def circumradius(p: Coord, q: Coord, r: Coord) -> tuple[float, int]:
    """Radius of the circle through p, q, r (metres) and the turn sign at q (+1 left, -1 right)."""
    ax, ay = _local_xy(q, p)
    cx, cy = _local_xy(q, r)
    cross = ax * cy - ay * cx  # twice the signed triangle area (q at the origin)
    if abs(cross) < 1e-9:
        return math.inf, 0
    a = math.hypot(ax, ay)
    b = math.hypot(cx, cy)
    c = math.hypot(cx - ax, cy - ay)
    # sign: travelling p -> q -> r, a left turn has r to the left of the p->q direction
    direction = (-ax) * (cy) - (-ay) * (cx)
    return (a * b * c) / (2 * abs(cross)), 1 if direction > 0 else -1


def merge_close(coords: Sequence[Coord], min_m: float) -> list[Coord]:
    """Drop vertices closer than min_m to their kept neighbour; both endpoints are always kept.

    Forwards, a vertex closer than min_m to the last kept one is dropped. The end gets the same
    treatment backwards: kept vertices closer than min_m to the last vertex are dropped. So
    consecutive output vertices are at least min_m apart, unless the whole line is shorter, in
    which case only the two endpoints remain.
    """
    if len(coords) <= 2:
        return list(coords)
    out = [coords[0]]
    for p in coords[1:-1]:
        if haversine_m(out[-1], p) >= min_m:
            out.append(p)
    out.append(coords[-1])
    while len(out) > 2 and haversine_m(out[-2], out[-1]) < min_m:
        del out[-2]
    return out
