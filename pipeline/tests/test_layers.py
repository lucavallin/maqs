import pytest

from maqs.layers import LAYER_SCHEMA_VERSION, STANDARD_LAYERS, output_name


def test_every_standard_layer_has_schema_version_one_today():
    assert STANDARD_LAYERS == ("basemap", "terrain", "trails", "places", "curvature")
    assert {LAYER_SCHEMA_VERSION[layer] for layer in STANDARD_LAYERS} == {1}
    assert LAYER_SCHEMA_VERSION["terrain-hd"] == 1


def test_output_name_carries_the_schema_version():
    assert output_name("veneto", "trails", "sqlite") == "veneto-trails.v1.sqlite"
    assert (
        output_name("base-triveneto", "basemap", "pmtiles") == "base-triveneto-basemap.v1.pmtiles"
    )


def test_output_name_rejects_an_unknown_layer():
    with pytest.raises(KeyError):
        output_name("veneto", "roads", "sqlite")
