import hashlib

import pytest

from maqs import validate
from maqs.validate import Expectation, ValidationError, sha256, validate_output
from tests.helpers import write_pmtiles

BASEMAP = Expectation(min_zoom=0, max_zoom=14, tile_types=frozenset({"mvt"}), source="https://x")
TERRAIN = Expectation(min_zoom=0, max_zoom=12, tile_types=frozenset({"webp", "png"}))


def test_sha256_matches_hashlib(tmp_path):
    p = tmp_path / "f"
    p.write_bytes(b"maqs" * 1000)
    assert sha256(p) == hashlib.sha256(b"maqs" * 1000).hexdigest()


def test_valid_basemap_passes_and_reports(tmp_path):
    p = write_pmtiles(
        tmp_path / "x-basemap.pmtiles",
        tile_type=1,
        max_zoom=14,
        metadata={
            "attribution": "© OSM",
            "planetiler:osm:osmosisreplicationtime": "2026-06-07T23:59:58Z",
        },
    )
    info = validate_output(p, BASEMAP)
    assert info.file == "x-basemap.pmtiles" and info.tiles == 1 and info.compression == "gzip"
    assert info.attribution == "© OSM" and info.source_data_date == "2026-06-07T23:59:58Z"
    assert info.sha256 == sha256(p) and info.bytes == p.stat().st_size
    assert info.source == "https://x"


def test_source_defaults_to_none(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=4, max_zoom=12, tile_compression=1)
    assert validate_output(p, TERRAIN).source is None


def test_rejects_an_unclustered_archive(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    data = bytearray(p.read_bytes())
    data[96] = 0  # clustered byte
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError, match="not clustered"):
        validate_output(p, BASEMAP)


def test_rejects_mlt_where_only_mvt_is_allowed(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", tile_type=6, max_zoom=14)
    with pytest.raises(ValidationError, match=r"tile type mlt, expected one of \['mvt'\]"):
        validate_output(p, BASEMAP)


def test_rejects_brotli(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    data = bytearray(p.read_bytes())
    data[98] = 3  # tile compression byte -> brotli
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError, match="tile compression brotli"):
        validate_output(p, BASEMAP)


def test_rejects_wrong_zoom_range(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=12)
    with pytest.raises(ValidationError, match="zoom range 0-12, expected 0-14"):
        validate_output(p, BASEMAP)


def test_rejects_wrong_tile_type(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=1, max_zoom=12, tile_compression=1)
    with pytest.raises(ValidationError, match="tile type mvt"):
        validate_output(p, TERRAIN)


def test_rejects_zero_tiles(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    data = bytearray(p.read_bytes())
    data[72:80] = (0).to_bytes(8, "little")  # addressed tiles
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError, match="zero tiles"):
        validate_output(p, BASEMAP)


def test_rejects_truncated_file(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    p.write_bytes(p.read_bytes()[:60])
    with pytest.raises(ValidationError, match="truncated"):
        validate_output(p, BASEMAP)


def test_rejects_truncated_tile_data(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    p.write_bytes(p.read_bytes()[:-5])
    with pytest.raises(ValidationError, match="truncated"):
        validate_output(p, BASEMAP)


def test_internal_compression_failure_is_listed_with_others(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=12)
    data = bytearray(p.read_bytes())
    data[97] = 3  # internal compression byte -> brotli
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError) as exc:
        validate_output(p, BASEMAP)
    assert "internal compression brotli" in str(exc.value) and "zoom range" in str(exc.value)


def test_size_cap_boundary(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    size = p.stat().st_size
    validate_output(p, Expectation(0, 14, frozenset({"mvt"}), size_cap=size + 1))
    with pytest.raises(ValidationError, match="exceeds the size cap"):
        validate_output(p, Expectation(0, 14, frozenset({"mvt"}), size_cap=size))


def test_lists_every_failure_at_once(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", tile_type=4, max_zoom=12, tile_compression=1)
    with pytest.raises(ValidationError) as exc:
        validate_output(p, BASEMAP)
    assert "tile type webp" in str(exc.value) and "zoom range" in str(exc.value)


def test_constants():
    assert int(1.9 * 2**30) == validate.SIZE_CAP
    assert validate.BASE_PACK_CAP == 15_000_000
