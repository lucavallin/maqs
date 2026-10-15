import gzip
import struct

import pytest

from maqs.pmtiles_header import PMTilesError
from maqs.pmtiles_reader import (
    Entry,
    PMTilesArchive,
    find_entry,
    read_directory,
    zxy_to_tile_id,
)
from tests.helpers import _varint, write_pmtiles


@pytest.mark.parametrize(
    "zxy, tile_id",
    [
        ((0, 0, 0), 0),
        ((1, 0, 0), 1),
        ((1, 0, 1), 2),
        ((1, 1, 1), 3),
        ((1, 1, 0), 4),
        ((2, 0, 0), 5),
    ],
)
def test_zxy_to_tile_id_matches_the_spec_order(zxy, tile_id):
    assert zxy_to_tile_id(*zxy) == tile_id


def test_zxy_to_tile_id_rejects_out_of_range():
    with pytest.raises(ValueError):
        zxy_to_tile_id(1, 2, 0)
    with pytest.raises(ValueError):
        zxy_to_tile_id(32, 0, 0)


def test_read_directory_decodes_deltas_and_implicit_offsets():
    # two entries: id 5 len 10 at offset 0, id 7 len 20 at offset 10 (implicit), one leaf
    # pointer id 9
    data = (
        _varint(3)
        + _varint(5)
        + _varint(2)
        + _varint(2)
        + _varint(1)
        + _varint(1)
        + _varint(0)
        + _varint(10)
        + _varint(20)
        + _varint(99)
        + _varint(1)
        + _varint(0)
        + _varint(501)
    )
    entries = read_directory(data)
    assert entries == [Entry(5, 0, 10, 1), Entry(7, 10, 20, 1), Entry(9, 500, 99, 0)]
    assert find_entry(entries, 5) == entries[0] and find_entry(entries, 7) == entries[1]
    assert find_entry(entries, 6) is None and find_entry(entries, 9) == entries[2]


def test_read_directory_run_length_covers_a_range():
    data = _varint(1) + _varint(10) + _varint(4) + _varint(8) + _varint(1)
    (entry,) = read_directory(data)
    assert entry == Entry(10, 0, 8, 4)
    assert find_entry([entry], 13) == entry and find_entry([entry], 14) is None


def test_read_directory_rejects_truncated_data():
    with pytest.raises(PMTilesError, match="directory"):
        read_directory(_varint(2) + _varint(5))


def test_read_directory_rejects_an_entry_count_larger_than_the_data():
    with pytest.raises(PMTilesError, match="directory claims"):
        read_directory(_varint(1_000_000_000) + _varint(1))


def test_archive_returns_the_decompressed_tile(tmp_path):
    tile_id = zxy_to_tile_id(12, 2187, 1455)
    p = write_pmtiles(
        tmp_path / "a.pmtiles", tile_type=1, max_zoom=12, tile=b"hello-tile", tile_id=tile_id
    )
    archive = PMTilesArchive(p)
    assert archive.tile(12, 2187, 1455) == b"hello-tile"
    assert archive.tile(12, 2188, 1455) is None


def test_archive_returns_uncompressed_tile_as_is(tmp_path):
    p = write_pmtiles(
        tmp_path / "t.pmtiles",
        tile_type=4,
        max_zoom=12,
        tile_compression=1,
        tile=b"RIFF....",
        tile_id=zxy_to_tile_id(12, 1, 1),
    )
    assert PMTilesArchive(p).tile(12, 1, 1) == b"RIFF...."


def test_archive_follows_a_leaf_directory(tmp_path):
    tile_id = zxy_to_tile_id(12, 5, 6)
    tile = b"leaf-tile"
    leaf = gzip.compress(
        _varint(1) + _varint(tile_id) + _varint(1) + _varint(len(tile)) + _varint(1), mtime=0
    )
    # root: one leaf pointer (run length 0) at leaf offset 0
    root = gzip.compress(_varint(1) + _varint(0) + _varint(0) + _varint(len(leaf)) + _varint(1))
    meta = gzip.compress(b"{}", mtime=0)
    root_off = 127
    meta_off = root_off + len(root)
    leaf_off = meta_off + len(meta)
    data_off = leaf_off + len(leaf)
    header = bytearray(b"PMTiles\x03")
    header += struct.pack(
        "<QQQQQQQQQQQ",
        root_off,
        len(root),
        meta_off,
        len(meta),
        leaf_off,
        len(leaf),
        data_off,
        len(tile),
        1,
        1,
        1,
    )
    header += bytes([1, 2, 1, 1, 0, 12]) + struct.pack("<iiii", 0, 0, 1, 1)
    header += bytes([0]) + struct.pack("<ii", 0, 0)
    p = tmp_path / "leaf.pmtiles"
    p.write_bytes(bytes(header) + root + meta + leaf + tile)
    archive = PMTilesArchive(p)
    assert archive.tile(12, 5, 6) == b"leaf-tile"
    assert archive.tile(12, 5, 7) is None


def test_archive_rejects_tile_beyond_eof(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", max_zoom=12, tile=b"x" * 100, tile_id=0)
    data = bytearray(p.read_bytes())
    # inflate the tile data length in the header (bytes 64..72) past the file end
    data[64:72] = (10_000).to_bytes(8, "little")
    p.write_bytes(bytes(data))
    with pytest.raises(PMTilesError, match="truncated"):
        PMTilesArchive(p)


def test_archive_rejects_entry_beyond_the_tile_data_section(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", max_zoom=12, tile=b"x" * 100, tile_id=0)
    data = bytearray(p.read_bytes())
    # shrink the declared tile data length so the directory entry points past it
    data[64:72] = (10).to_bytes(8, "little")
    p.write_bytes(bytes(data))
    with pytest.raises(PMTilesError, match="beyond the tile data"):
        PMTilesArchive(p).tile(0, 0, 0)


def test_archive_rejects_gzip_bomb_tile(tmp_path):
    bomb = gzip.compress(b"\0" * (70 * 1024 * 1024), mtime=0)
    p = tmp_path / "b.pmtiles"
    # write the archive with the precompressed blob by bypassing the helper's compression
    write_pmtiles(p, max_zoom=12, tile_compression=1, tile=bomb, tile_id=0)
    data = bytearray(p.read_bytes())
    data[98] = 2  # declare gzip tile compression
    p.write_bytes(bytes(data))
    with pytest.raises(PMTilesError, match="exceeds"):
        PMTilesArchive(p).tile(0, 0, 0)
