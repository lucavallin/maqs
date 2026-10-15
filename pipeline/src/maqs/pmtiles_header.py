"""Reads the fixed 127-byte PMTiles v3 header and the metadata JSON.

Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md (verified 2026-10-07).
Used for validation so the pipeline never parses a tool's human-readable output.
"""

from __future__ import annotations

import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

HEADER_SIZE = 127
MAX_METADATA_BYTES = 8 * 1024 * 1024
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
    header = Header(
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
    file_size = path.stat().st_size
    sections = {
        "root directory": (header.root_dir_offset, header.root_dir_length),
        "metadata": (header.metadata_offset, header.metadata_length),
        "leaf directories": (header.leaf_dirs_offset, header.leaf_dirs_length),
        "tile data": (header.tile_data_offset, header.tile_data_length),
    }
    for name, (offset, length) in sections.items():
        if offset + length > file_size:
            raise PMTilesError(
                f"{path}: truncated {name} (ends at {offset + length}, file is {file_size} bytes)"
            )
    return header


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
        raw = _gunzip_bounded(path, raw)
    elif header.internal_compression != "none":
        raise PMTilesError(
            f"{path}: unsupported internal compression {header.internal_compression}"
        )
    try:
        metadata = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PMTilesError(f"{path}: metadata is not JSON") from exc
    if not isinstance(metadata, dict):
        raise PMTilesError(f"{path}: metadata is not a JSON object")
    return metadata


def _gunzip_bounded(path: Path, raw: bytes) -> bytes:
    """Decompress gzip metadata, refusing output beyond MAX_METADATA_BYTES (gzip bombs)."""
    decompressor = zlib.decompressobj(wbits=31)
    try:
        out = decompressor.decompress(raw, MAX_METADATA_BYTES + 1)
    except zlib.error as exc:
        raise PMTilesError(f"{path}: metadata is not valid gzip") from exc
    if len(out) > MAX_METADATA_BYTES or decompressor.unconsumed_tail:
        raise PMTilesError(f"{path}: metadata exceeds {MAX_METADATA_BYTES} bytes")
    if not decompressor.eof:
        raise PMTilesError(f"{path}: metadata is not valid gzip")
    return out
