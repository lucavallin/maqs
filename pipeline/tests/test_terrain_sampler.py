import io

import pytest
from PIL import Image

from maqs.osm.terrain_sampler import TerrainSampler, ascent_descent, lonlat_to_pixel, terrarium_to_m
from maqs.pmtiles_header import PMTilesError
from maqs.pmtiles_reader import zxy_to_tile_id
from tests.helpers import write_pmtiles

SIZE = 512
TEST_TILE = zxy_to_tile_id(12, 2187, 1455)


def terrarium_tile(elevation_at) -> bytes:
    """A lossless WebP terrarium tile whose elevation at (px, py) is elevation_at(px, py)."""
    img = Image.new("RGB", (SIZE, SIZE))
    pixels = img.load()
    for py in range(SIZE):
        for px in range(SIZE):
            v = elevation_at(px, py) + 32768.0
            whole = int(v)
            pixels[px, py] = (whole // 256, whole % 256, int(round((v - whole) * 256)) % 256)
    out = io.BytesIO()
    img.save(out, "WEBP", lossless=True)
    return out.getvalue()


def test_terrarium_decode():
    assert terrarium_to_m(128, 0, 0) == 0.0
    assert terrarium_to_m(131, 232, 128) == pytest.approx(1000.5)


def test_lonlat_to_pixel_center_of_the_test_bbox():
    tx, ty, px, py = lonlat_to_pixel(12.25, 46.105, 12, SIZE)
    assert (tx, ty) == (2187, 1455)
    assert 0 <= px < SIZE and 0 <= py < SIZE


@pytest.fixture
def archive(tmp_path):
    tile = terrarium_tile(lambda px, py: 1000.0 + px)  # 1 m per pixel eastwards
    return write_pmtiles(
        tmp_path / "terrain.pmtiles",
        tile_type=4,
        min_zoom=0,
        max_zoom=12,
        tile_compression=1,
        tile=tile,
        tile_id=TEST_TILE,
    )


def test_elevation_is_bilinear_within_the_tile(archive):
    sampler = TerrainSampler(archive)
    assert sampler.zoom == 12
    _, _, px, _ = lonlat_to_pixel(12.25, 46.105, 12, SIZE)
    e = sampler.elevation(12.25, 46.105)
    assert e == pytest.approx(1000.0 + px - 0.5, abs=0.01)  # pixel centres sit at +0.5


def test_elevation_is_none_outside_coverage(archive):
    sampler = TerrainSampler(archive)
    assert sampler.elevation(13.5, 46.105) is None  # no tile there
    assert sampler.elevation(200.0, 46.105) is None  # off the world
    assert sampler.elevation(12.25, 89.0) is None  # beyond Web Mercator
    assert sampler.elevation(float("nan"), 46.105) is None


def test_tile_cache_is_bounded(archive):
    sampler = TerrainSampler(archive, max_tiles=2)
    for lon in (13.0, 13.1, 13.2, 13.3):
        sampler.elevation(lon, 46.105)
    assert len(sampler._tiles) == 2


def test_undecodable_tile_is_a_typed_error(tmp_path):
    p = write_pmtiles(
        tmp_path / "bad.pmtiles",
        tile_type=4,
        max_zoom=12,
        tile_compression=1,
        tile=b"not an image",
        tile_id=TEST_TILE,
    )
    with pytest.raises(PMTilesError, match="not a readable image"):
        TerrainSampler(p).elevation(12.25, 46.105)


def test_ascent_descent_with_hysteresis(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    # 9 samples: 0, 25, ..., 175 m and the endpoint at ~190 m. +12 (the +2/+4 steps stay under
    # the hysteresis until 112), -9, +17.
    profile = iter([100.0, 102.0, 104.0, 112.0, 111.0, 103.0, 103.0, 120.0, 120.0])
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: next(profile))
    coords = [(12.25, 46.10), (12.2525, 46.10)]  # ~190 m
    ascent, descent, missing = ascent_descent(sampler, coords)
    assert ascent == pytest.approx(29.0) and descent == pytest.approx(9.0) and missing == 0


def test_ascent_descent_counts_missing_samples(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    # 5 samples: 0, 25, 50, 75 m and the endpoint at ~77 m
    values = iter([100.0, None, None, 130.0, 130.0])
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: next(values))
    ascent, descent, missing = ascent_descent(sampler, [(12.25, 46.10), (12.2510, 46.10)])
    assert ascent == pytest.approx(30.0) and descent == 0.0 and missing == 2


def test_ascent_descent_all_missing_is_none(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: None)
    result = ascent_descent(sampler, [(13.5, 46.1), (13.51, 46.1)])
    assert result == (None, None, 32)
