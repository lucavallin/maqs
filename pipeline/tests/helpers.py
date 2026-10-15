"""Builds tiny, valid PMTiles v3 archives so tests never need binaries in git."""

from __future__ import annotations

import gzip
import json
import struct
from pathlib import Path


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _compress(data: bytes, compression: int) -> bytes:
    if compression == 2:
        return gzip.compress(data, mtime=0)
    if compression == 1:
        return data
    raise ValueError(f"helper supports none/gzip only, got {compression}")


def write_pmtiles(
    path: Path,
    *,
    tile_type: int = 1,
    min_zoom: int = 0,
    max_zoom: int = 0,
    tile_compression: int = 2,
    internal_compression: int = 2,
    metadata: dict | None = None,
    tile: bytes = b"\x1a\x00",
    tile_id: int = 0,
    bbox: tuple[float, float, float, float] = (12.21, 46.08, 12.29, 46.13),
) -> Path:
    tile_blob = _compress(tile, tile_compression) if tile_compression != 1 else tile
    # one entry: tile id, run length 1, length, offset encoded as offset+1
    directory = _varint(1) + _varint(tile_id) + _varint(1) + _varint(len(tile_blob)) + _varint(1)
    root = _compress(directory, internal_compression)
    meta = _compress(json.dumps(metadata or {}).encode(), internal_compression)
    root_offset = 127
    meta_offset = root_offset + len(root)
    leaf_offset = meta_offset + len(meta)
    data_offset = leaf_offset
    header = bytearray(b"PMTiles\x03")
    header += struct.pack(
        "<QQQQQQQQQQQ",
        root_offset,
        len(root),
        meta_offset,
        len(meta),
        leaf_offset,
        0,
        data_offset,
        len(tile_blob),
        1,
        1,
        1,
    )
    header += bytes([1, internal_compression, tile_compression, tile_type, min_zoom, max_zoom])
    header += struct.pack("<iiii", *(int(v * 1e7) for v in bbox))
    center_lon = int(((bbox[0] + bbox[2]) / 2) * 1e7)
    center_lat = int(((bbox[1] + bbox[3]) / 2) * 1e7)
    header += bytes([min_zoom]) + struct.pack("<ii", center_lon, center_lat)
    assert len(header) == 127, len(header)
    path.write_bytes(bytes(header) + root + meta + tile_blob)
    return path
