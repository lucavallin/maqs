import copy
import json
from pathlib import Path
from typing import Any

import pytest

from maqs.map_style import DARK, LIGHT, Palette, main, transform

LICENSE_URL = "https://creativecommons.org/publicdomain/zero/1.0/"


def layer(layer_id: str, kind: str, **extra: Any) -> dict[str, Any]:
    return {"id": layer_id, "type": kind, **extra}


def sample_style() -> dict[str, Any]:
    return {
        "version": 8,
        "name": "versatiles-muted",
        "metadata": {"license": LICENSE_URL},
        "glyphs": "https://tiles.versatiles.org/assets/glyphs/{fontstack}/{range}.pbf",
        "sprite": [{"id": "base", "url": "https://tiles.versatiles.org/assets/sprites/base"}],
        "sources": {
            "versatiles-shortbread": {
                "type": "vector",
                "tiles": ["https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"],
                "attribution": '<a href="https://www.openstreetmap.org/copyright">OSM</a>',
            },
            "elevation": {
                "type": "raster-dem",
                "encoding": "terrarium",
                "tiles": ["https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}"],
            },
        },
        "terrain": {"source": "elevation", "exaggeration": 1},
        "sky": {"sky-color": "rgb(1,2,3)"},
        "projection": {"type": "globe"},
        "layers": [
            layer("background", "background", paint={"background-color": "rgb(244,240,238)"}),
            layer("slot-below-fills", "background"),
            layer(
                "water-ocean",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgb(208,221,233)", "fill-opacity": 0.5},
            ),
            layer(
                "water-river",
                "line",
                source="versatiles-shortbread",
                paint={"line-color": "rgb(188,206,223)"},
            ),
            layer(
                "water-pier-area",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgb(244,240,238)"},
            ),
            layer(
                "land-forest",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgb(215,228,206)"},
            ),
            layer(
                "land-park",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgba(214,220,197,0.5)"},
            ),
            layer(
                "land-residential",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgb(240,238,236)"},
            ),
            layer(
                "street-minor",
                "line",
                source="versatiles-shortbread",
                paint={"line-color": "rgb(249,249,249)", "line-width": 2},
            ),
            layer(
                "street-minor:outline",
                "line",
                source="versatiles-shortbread",
                paint={"line-color": "rgb(210,209,207)"},
            ),
            layer(
                "street-pedestrian-zone",
                "fill",
                source="versatiles-shortbread",
                paint={"fill-color": "rgb(244,234,246)"},
            ),
            layer(
                "bridge-street-minor:bridge",
                "line",
                source="versatiles-shortbread",
                paint={"line-color": "rgb(10,10,10)"},
            ),
            layer(
                "bridge-street-minor",
                "line",
                source="versatiles-shortbread",
                paint={"line-color": "rgb(249,249,249)"},
            ),
            layer(
                "hillshade",
                "hillshade",
                source="elevation",
                paint={"hillshade-exaggeration": 0.1, "hillshade-shadow-color": "rgb(0,0,0)"},
            ),
            layer(
                "street-label",
                "symbol",
                source="versatiles-shortbread",
                layout={"text-field": ["get", "name"], "icon-image": "base:icon-fuel_pump"},
            ),
            layer(
                "place-bold",
                "symbol",
                source="versatiles-shortbread",
                layout={"text-field": ["get", "name"], "text-font": ["noto_sans_bold"]},
            ),
            layer(
                "marking-oneway",
                "symbol",
                source="versatiles-shortbread",
                layout={
                    "icon-image": [
                        "match",
                        ["get", "kind"],
                        "a",
                        "base:marking-oneway",
                        "base:other",
                    ]
                },
            ),
            layer(
                "poi-amenity",
                "symbol",
                source="versatiles-shortbread",
                layout={"text-field": ["get", "name"], "icon-image": "base:icon-cafe"},
            ),
            layer("poi-tourism", "symbol", source="versatiles-shortbread"),
        ],
    }


def by_id(style: dict[str, Any], layer_id: str) -> dict[str, Any]:
    return next(item for item in style["layers"] if item["id"] == layer_id)


def test_sources_are_renamed_and_become_placeholders() -> None:
    style = transform(sample_style(), LIGHT)
    assert style["sources"] == {
        "basemap": {"type": "vector", "tiles": ["maqs://placeholder"]},
        "terrain": {"type": "raster-dem", "tiles": ["maqs://placeholder"]},
    }
    assert by_id(style, "water-ocean")["source"] == "basemap"
    assert by_id(style, "hillshade")["source"] == "terrain"
    assert "source" not in by_id(style, "background")


def test_glyphs_and_sprite_become_tokens() -> None:
    style = transform(sample_style(), LIGHT)
    assert style["glyphs"] == "maqs://glyphs"
    assert style["sprite"] == "maqs://sprite"


def test_icon_names_lose_the_sprite_prefix_everywhere() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "street-label")["layout"]["icon-image"] == "icon-fuel_pump"
    assert by_id(style, "marking-oneway")["layout"]["icon-image"] == [
        "match",
        ["get", "kind"],
        "a",
        "marking-oneway",
        "other",
    ]
    assert "base:" not in json.dumps(style)


def test_text_font_is_added_only_where_there_is_a_text_field() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "street-label")["layout"]["text-font"] == ["noto_sans_regular"]
    assert by_id(style, "place-bold")["layout"]["text-font"] == ["noto_sans_bold"]
    assert "text-font" not in by_id(style, "marking-oneway")["layout"]


def test_poi_layers_are_marked_and_hidden_but_keep_their_layout() -> None:
    style = transform(sample_style(), LIGHT)
    amenity = by_id(style, "poi-amenity")
    assert amenity["metadata"] == {"maqs:poi-key": "amenity"}
    assert amenity["layout"]["visibility"] == "none"
    assert amenity["layout"]["icon-image"] == "icon-cafe"
    tourism = by_id(style, "poi-tourism")
    assert tourism["metadata"] == {"maqs:poi-key": "tourism"}
    assert tourism["layout"] == {"visibility": "none"}


@pytest.mark.parametrize(("palette", "dark"), [(LIGHT, False), (DARK, True)])
def test_colour_groups_take_the_palette(palette: Palette, dark: bool) -> None:
    style = transform(sample_style(), palette)
    assert by_id(style, "background")["paint"]["background-color"] == palette.base
    assert by_id(style, "water-ocean")["paint"]["fill-color"] == palette.water
    assert by_id(style, "water-ocean")["paint"]["fill-opacity"] == 0.5
    assert by_id(style, "water-river")["paint"]["line-color"] == palette.water
    assert by_id(style, "land-forest")["paint"]["fill-color"] == palette.green
    assert by_id(style, "street-minor")["paint"]["line-color"] == palette.road
    assert by_id(style, "street-minor")["paint"]["line-width"] == 2
    assert (palette.base == "#191F28") is dark


def test_piers_and_dams_take_the_base_colour_not_the_water_colour() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "water-pier-area")["paint"]["fill-color"] == LIGHT.base


def test_green_keeps_the_alpha_of_the_original_colour() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "land-park")["paint"]["fill-color"] == "rgba(208,238,233,0.5)"


def test_other_layers_keep_their_colours() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "land-residential")["paint"]["fill-color"] == "rgb(240,238,236)"
    assert by_id(style, "street-minor:outline")["paint"]["line-color"] == "rgb(210,209,207)"
    assert by_id(style, "street-pedestrian-zone")["paint"]["fill-color"] == "rgb(244,234,246)"
    assert by_id(style, "bridge-street-minor:bridge")["paint"]["line-color"] == "rgb(10,10,10)"
    assert by_id(style, "slot-below-fills") == {"id": "slot-below-fills", "type": "background"}


def test_bridge_street_fills_take_the_road_colour() -> None:
    style = transform(sample_style(), LIGHT)
    assert by_id(style, "bridge-street-minor")["paint"]["line-color"] == LIGHT.road


def test_the_hillshade_layer_keeps_its_values() -> None:
    original = sample_style()
    style = transform(original, LIGHT)
    assert by_id(style, "hillshade")["paint"] == by_id(original, "hillshade")["paint"]


def test_the_dark_hillshade_has_a_dimmer_highlight_and_a_lighter_shadow() -> None:
    original = sample_style()
    paint = by_id(transform(original, DARK), "hillshade")["paint"]
    assert paint["hillshade-highlight-color"] == "rgba(255,255,255,0.4)"
    assert paint["hillshade-shadow-color"] == "rgba(0,0,0,0.6)"
    # The rest keeps VersaTiles' values, as the light style does.
    softened = ("hillshade-highlight-color", "hillshade-shadow-color")
    kept = {key: value for key, value in paint.items() if key not in softened}
    assert kept == {
        key: value
        for key, value in by_id(original, "hillshade")["paint"].items()
        if key not in softened
    }


def test_three_d_terrain_sky_and_projection_are_dropped() -> None:
    style = transform(sample_style(), LIGHT)
    assert "terrain" not in style
    assert "sky" not in style
    assert "projection" not in style


def test_metadata_names_the_style_and_keeps_the_licence_without_a_bare_url() -> None:
    light = transform(sample_style(), LIGHT)
    dark = transform(sample_style(), DARK)
    assert light["metadata"]["maqs:style"] == "default-light"
    assert dark["metadata"]["maqs:style"] == "default-dark"
    assert LICENSE_URL in light["metadata"]["license"]
    assert not light["metadata"]["license"].startswith("http")


def test_transform_does_not_mutate_its_input() -> None:
    original = sample_style()
    snapshot = copy.deepcopy(original)
    transform(original, LIGHT)
    assert original == snapshot


def test_transform_names_no_remote_url() -> None:
    def strings(node: Any) -> list[str]:
        if isinstance(node, str):
            return [node]
        if isinstance(node, list):
            return [text for item in node for text in strings(item)]
        if isinstance(node, dict):
            return [text for item in node.values() for text in strings(item)]
        return []

    for palette in (LIGHT, DARK):
        remote = [t for t in strings(transform(sample_style(), palette)) if t.startswith("http")]
        assert remote == []


def test_main_writes_both_styles(tmp_path: Path) -> None:
    source = tmp_path / "styles"
    for folder in ("muted-terrain", "muted-dark-terrain"):
        (source / folder).mkdir(parents=True)
        (source / folder / "style.json").write_text(json.dumps(sample_style()))
    out = tmp_path / "out"
    assert main([str(source), str(out)]) == 0
    light_text = (out / "default-light.json").read_text()
    assert light_text.endswith("\n")
    assert json.loads(light_text) == transform(sample_style(), LIGHT)
    assert light_text == json.dumps(json.loads(light_text), indent=1, sort_keys=False) + "\n"
    assert json.loads((out / "default-dark.json").read_text()) == transform(sample_style(), DARK)
