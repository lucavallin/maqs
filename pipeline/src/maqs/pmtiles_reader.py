"""Tile lookup in a local PMTiles v3 archive: Hilbert tile ids, directories, leaf directories.

Everything is bounds-checked against the file; a corrupt directory or an oversized tile is a
PMTilesError. Only what the terrain sampler needs; the Swift reader mirrors it.
"""

from __future__ import annotations

from bisect import bisect_right
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from maqs.pmtiles_header import Header, PMTilesError, inflate_gzip, read_header

MAX_TILE_BYTES = 64 * 1024 * 1024
MAX_DIRECTORY_BYTES = 16 * 1024 * 1024


def zxy_to_tile_id(z: int, x: int, y: int) -> int:
    """The PMTiles v3 tile id: position along the Hilbert curve, after all lower zooms."""
    if z < 0 or z > 31:
        raise ValueError(f"zoom {z} out of range 0..31")
    n = 1 << z
    if not (0 <= x < n and 0 <= y < n):
        raise ValueError(f"tile {x}/{y} out of range for zoom {z}")
    acc = ((1 << (2 * z)) - 1) // 3  # tiles in all lower zooms
    d = 0
    s = n >> 1
    while s > 0:
        rx = 1 if x & s else 0
        ry = 1 if y & s else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x, y = n - 1 - x, n - 1 - y
            x, y = y, x
        s >>= 1
    return acc + d


@dataclass(frozen=True)
class Entry:
    tile_id: int
    offset: int
    length: int
    run_length: int  # 0 = pointer to a leaf directory


def _read_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        if pos >= len(data):
            raise PMTilesError("truncated directory varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise PMTilesError("directory varint too long")


def read_directory(data: bytes) -> list[Entry]:
    count, pos = _read_varint(data, 0)
    # Each entry needs at least four bytes, so a larger count is corrupt (and must not drive
    # a huge allocation).
    if count * 4 > len(data):
        raise PMTilesError(f"directory claims {count} entries in {len(data)} bytes")
    ids: list[int] = []
    last = 0
    for _ in range(count):
        delta, pos = _read_varint(data, pos)
        last += delta
        ids.append(last)
    runs: list[int] = []
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        runs.append(value)
    lengths: list[int] = []
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        lengths.append(value)
    offsets: list[int] = []
    for i in range(count):
        value, pos = _read_varint(data, pos)
        if value == 0 and i > 0:
            offsets.append(offsets[i - 1] + lengths[i - 1])
        else:
            offsets.append(value - 1)
        if offsets[i] < 0:
            raise PMTilesError("directory entry has a negative tile offset")
    return [Entry(ids[i], offsets[i], lengths[i], runs[i]) for i in range(count)]


def find_entry(entries: Sequence[Entry], tile_id: int) -> Entry | None:
    i = bisect_right(entries, tile_id, key=lambda e: e.tile_id) - 1
    if i < 0:
        return None
    entry = entries[i]
    if entry.run_length == 0:
        return entry  # leaf pointer: covers every id from its tile_id to the next entry
    if tile_id < entry.tile_id + entry.run_length:
        return entry
    return None


class PMTilesArchive:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.header: Header = read_header(path)
        self._root = read_directory(
            self._section(
                self.header.root_dir_offset, self.header.root_dir_length, MAX_DIRECTORY_BYTES
            )
        )

    def _read(self, offset: int, length: int) -> bytes:
        with self.path.open("rb") as f:
            f.seek(offset)
            data = f.read(length)
        if len(data) != length:
            raise PMTilesError(f"{self.path}: truncated read at {offset}+{length}")
        return data

    def _section(self, offset: int, length: int, cap: int) -> bytes:
        if length > cap:
            raise PMTilesError(f"{self.path}: section of {length} bytes exceeds {cap}")
        raw = self._read(offset, length)
        compression = self.header.internal_compression
        if compression == "gzip":
            return inflate_gzip(raw, cap)
        if compression == "none":
            return raw
        raise PMTilesError(f"{self.path}: unsupported internal compression {compression}")

    def tile(self, z: int, x: int, y: int) -> bytes | None:
        """The decompressed tile, or None when the archive has no such tile."""
        tile_id = zxy_to_tile_id(z, x, y)
        entry = find_entry(self._root, tile_id)
        if entry is not None and entry.run_length == 0:
            if entry.offset + entry.length > self.header.leaf_dirs_length:
                raise PMTilesError(f"{self.path}: leaf directory beyond the leaf section")
            leaf = read_directory(
                self._section(
                    self.header.leaf_dirs_offset + entry.offset, entry.length, MAX_DIRECTORY_BYTES
                )
            )
            entry = find_entry(leaf, tile_id)
            if entry is not None and entry.run_length == 0:
                raise PMTilesError(f"{self.path}: nested leaf directories are not supported")
        if entry is None:
            return None
        if entry.length > MAX_TILE_BYTES:
            raise PMTilesError(
                f"{self.path}: tile of {entry.length} bytes exceeds {MAX_TILE_BYTES}"
            )
        if entry.offset + entry.length > self.header.tile_data_length:
            raise PMTilesError(f"{self.path}: tile entry beyond the tile data section")
        raw = self._read(self.header.tile_data_offset + entry.offset, entry.length)
        compression = self.header.tile_compression
        if compression == "gzip":
            return inflate_gzip(raw, MAX_TILE_BYTES)
        if compression == "none":
            return raw
        raise PMTilesError(f"{self.path}: unsupported tile compression {compression}")
