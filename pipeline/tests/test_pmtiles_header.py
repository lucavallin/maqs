import pytest

from maqs.pmtiles_header import PMTilesError, read_header, read_metadata
from tests.helpers import write_pmtiles


def test_reads_a_generated_archive(tmp_path):
    p = write_pmtiles(
        tmp_path / "a.pmtiles",
        tile_type=1,
        min_zoom=0,
        max_zoom=14,
        metadata={"attribution": "x"},
    )
    h = read_header(p)
    assert h.tile_type == "mvt"
    assert h.tile_compression == "gzip"
    assert h.internal_compression == "gzip"
    assert (h.min_zoom, h.max_zoom) == (0, 14)
    assert h.addressed_tiles == 1
    assert h.clustered is True
    assert h.bbox == pytest.approx((12.21, 46.08, 12.29, 46.13))
    assert read_metadata(p, h) == {"attribution": "x"}


def test_reads_webp_uncompressed(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=4, max_zoom=12, tile_compression=1)
    h = read_header(p)
    assert h.tile_type == "webp" and h.tile_compression == "none"


def test_rejects_bad_magic(tmp_path):
    p = tmp_path / "x.pmtiles"
    p.write_bytes(b"NOTPMTILES" + b"\x00" * 200)
    with pytest.raises(PMTilesError, match="not a PMTiles v3 archive"):
        read_header(p)


def test_rejects_truncated_file(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles")
    p.write_bytes(p.read_bytes()[:100])
    with pytest.raises(PMTilesError, match="truncated"):
        read_header(p)


def test_rejects_metadata_beyond_eof(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", metadata={"k": "v" * 100})
    data = p.read_bytes()
    p.write_bytes(data[:-50])
    h = read_header(p)
    with pytest.raises(PMTilesError, match="truncated"):
        read_metadata(p, h)
