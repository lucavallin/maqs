from pathlib import Path

import pytest

from maqs.config import ConfigError, load_config, union_bbox

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "regions.yaml"
    p.write_text(text)
    return p


MINIMAL = """
schema_version: 1
hd_max_zoom: 13
base_packs: []
regions:
  - id: a
    name: { it: A, en: A }
    bbox: [10.0, 45.0, 11.0, 46.0]
"""


def test_loads_the_real_config():
    cfg = load_config(REAL)
    assert cfg.schema_version == 1
    assert cfg.region("test").fixture is True
    assert cfg.region("veneto").osm == {"geofabrik": "europe/italy/nord-est"}
    assert cfg.region("veneto").clip == {"admin": [43648]}
    assert cfg.base_pack("triveneto").regions == ("triveneto",)
    assert cfg.geofabrik_extracts() == ["europe/italy/nord-est"]
    assert "test" not in cfg.region_ids(include_fixtures=False)
    assert "test" in cfg.region_ids(include_fixtures=True)


def test_minimal_config(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    r = cfg.region("a")
    assert r.bbox == (10.0, 45.0, 11.0, 46.0)
    assert r.fixture is False and r.osm is None and r.clip is None and r.hd_max_zoom is None
    assert r.bbox_border == 1


def test_real_config_builds_the_test_fixture_without_a_tile_border():
    cfg = load_config(REAL)
    assert cfg.region("test").bbox_border == 0
    assert cfg.region("veneto").bbox_border == 1


def test_explicit_bbox_border(tmp_path):
    text = MINIMAL.replace(
        "bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    bbox_border: 0"
    )
    assert load_config(write(tmp_path, text)).region("a").bbox_border == 0


@pytest.mark.parametrize("value", ["-1", "1.5", "'1'", "true"])
def test_rejects_bad_bbox_border(tmp_path, value):
    text = MINIMAL.replace(
        "bbox: [10.0, 45.0, 11.0, 46.0]",
        f"bbox: [10.0, 45.0, 11.0, 46.0]\n    bbox_border: {value}",
    )
    with pytest.raises(ConfigError, match=r"region 'a': bbox_border must be an integer >= 0"):
        load_config(write(tmp_path, text))


def test_union_bbox():
    assert union_bbox([(10, 45, 11, 46), (10.5, 44, 12, 45.5)]) == (10, 44, 12, 46)


def test_base_pack_bbox_is_the_union_of_its_regions(tmp_path):
    text = (
        MINIMAL
        + """
  - id: b
    name: { it: B, en: B }
    bbox: [12.0, 44.0, 13.0, 45.0]
"""
    )
    text = text.replace(
        "base_packs: []", "base_packs:\n  - { id: ab, regions: [a, b], max_zoom: 10 }"
    )
    cfg = load_config(write(tmp_path, text))
    assert cfg.base_pack_bbox(cfg.base_pack("ab")) == (10.0, 44.0, 13.0, 46.0)


@pytest.mark.parametrize(
    "bbox, message",
    [
        ("[11.0, 45.0, 10.0, 46.0]", "lon_min must be < lon_max"),
        ("[10.0, 46.0, 11.0, 45.0]", "lat_min must be < lat_max"),
        ("[-181.0, 45.0, 11.0, 46.0]", "longitude out of range"),
        ("[10.0, 45.0, 11.0, 91.0]", "latitude out of range"),
        ("[10.0, 45.0, 11.0]", "bbox must have 4 numbers"),
    ],
)
def test_rejects_bad_bbox(tmp_path, bbox, message):
    with pytest.raises(ConfigError, match=message) as exc:
        load_config(write(tmp_path, MINIMAL.replace("[10.0, 45.0, 11.0, 46.0]", bbox)))
    assert "region 'a'" in str(exc.value)


def test_rejects_bad_id(tmp_path):
    with pytest.raises(ConfigError, match="id 'Bad_Id' must match"):
        load_config(write(tmp_path, MINIMAL.replace("id: a", "id: Bad_Id")))


def test_rejects_duplicate_id(tmp_path):
    text = (
        MINIMAL
        + """
  - id: a
    name: { it: A, en: A }
    bbox: [10.0, 45.0, 11.0, 46.0]
"""
    )
    with pytest.raises(ConfigError, match="duplicate region id 'a'"):
        load_config(write(tmp_path, text))


def test_rejects_base_pack_with_unknown_or_fixture_region(tmp_path):
    text = MINIMAL.replace(
        "base_packs: []", "base_packs:\n  - { id: x, regions: [nope], max_zoom: 10 }"
    )
    with pytest.raises(ConfigError, match="base pack 'x' names unknown region 'nope'"):
        load_config(write(tmp_path, text))
    text = MINIMAL.replace(
        "base_packs: []", "base_packs:\n  - { id: x, regions: [a], max_zoom: 10 }"
    )
    text = text.replace(
        "bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    fixture: true"
    )
    with pytest.raises(ConfigError, match="base pack 'x' names fixture region 'a'"):
        load_config(write(tmp_path, text))


def test_rejects_unknown_schema_version(tmp_path):
    with pytest.raises(ConfigError, match="schema_version 2 is not supported"):
        load_config(write(tmp_path, MINIMAL.replace("schema_version: 1", "schema_version: 2")))


def test_unknown_region_raises_key_error(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    with pytest.raises(KeyError):
        cfg.region("zzz")
