"""Reads the fixed 127-byte PMTiles v3 header and the metadata JSON.

Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md (verified 2026-10-07).
Used for validation so the pipeline never parses a tool's human-readable output.
"""

from __future__ import annotations

import gzip
import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

HEADER_SIZE = 127
COMPRESSION = {0: "unknown", 1: "none", 2: "gzip", 3: "brotli", 4: "zstd"}
TILE_TYPE = {0: "unknown", 1: "mvt", 2: "png", 3: "jpeg", 4: "webp", 5: "avif", 6: "mlt"}


class PMTilesError(ValueError):
    """The file is not a readable PMTiles v3 archive."""


@dataclass(frozen=True)
class Header:
    root_dir_offset: int
    root_dir_length: int
    metadata_offset: int
    metadata_length: int
    leaf_dirs_offset: int
    leaf_dirs_length: int
    tile_data_offset: int
    tile_data_length: int
    addressed_tiles: int
    tile_entries: int
    tile_contents: int
    clustered: bool
    internal_compression: str
    tile_compression: str
    tile_type: str
    min_zoom: int
    max_zoom: int
    bbox: tuple[float, float, float, float]


def read_header(path: Path) -> Header:
    with path.open("rb") as f:
        raw = f.read(HEADER_SIZE)
    if len(raw) < HEADER_SIZE:
        raise PMTilesError(f"{path}: truncated header ({len(raw)} of {HEADER_SIZE} bytes)")
    if raw[:7] != b"PMTiles" or raw[7] != 3:
        raise PMTilesError(f"{path}: not a PMTiles v3 archive")
    offsets = struct.unpack_from("<QQQQQQQQQQQ", raw, 8)
    clustered, internal, tile_comp, tile_type, min_zoom, max_zoom = raw[96:102]
    lon_min, lat_min, lon_max, lat_max = struct.unpack_from("<iiii", raw, 102)
    return Header(
        *offsets[:8],
        addressed_tiles=offsets[8],
        tile_entries=offsets[9],
        tile_contents=offsets[10],
        clustered=clustered == 1,
        internal_compression=COMPRESSION.get(internal, "unknown"),
        tile_compression=COMPRESSION.get(tile_comp, "unknown"),
        tile_type=TILE_TYPE.get(tile_type, "unknown"),
        min_zoom=min_zoom,
        max_zoom=max_zoom,
        bbox=(lon_min / 1e7, lat_min / 1e7, lon_max / 1e7, lat_max / 1e7),
    )


def read_metadata(path: Path, header: Header) -> dict:
    # Bound the read by the file size so a hostile length cannot force a huge allocation.
    if header.metadata_offset + header.metadata_length > path.stat().st_size:
        raise PMTilesError(f"{path}: truncated metadata")
    with path.open("rb") as f:
        f.seek(header.metadata_offset)
        raw = f.read(header.metadata_length)
    if len(raw) < header.metadata_length:
        raise PMTilesError(f"{path}: truncated metadata")
    if header.internal_compression == "gzip":
        try:
            raw = gzip.decompress(raw)
        except (OSError, EOFError, zlib.error) as exc:
            raise PMTilesError(f"{path}: metadata is not valid gzip") from exc
    elif header.internal_compression != "none":
        raise PMTilesError(
            f"{path}: unsupported internal compression {header.internal_compression}"
        )
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PMTilesError(f"{path}: metadata is not JSON") from exc
