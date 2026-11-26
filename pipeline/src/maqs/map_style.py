"""The package's default map styles, derived from the VersaTiles muted terrain styles.

`python -m maqs.map_style STYLES_DIR OUT_DIR` reads `muted-terrain/style.json` and
`muted-dark-terrain/style.json` from the extracted VersaTiles `styles.tar.gz` and writes
`default-light.json` and `default-dark.json`. The output names no remote URL: sources, glyphs and
sprite are tokens the Swift style assembler fills in, so the same style serves online and offline.
`scripts/update-map-assets.sh` is the only caller.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PLACEHOLDER_URL = "maqs://placeholder"
SOURCE_NAMES = {"versatiles-shortbread": "basemap", "elevation": "terrain"}
SPRITE_PREFIX = "base:"
REGULAR_STACK = "noto_sans_regular"
BOLD_STACK = "noto_sans_bold"
GREEN_LAYERS = frozenset(
    {"land-forest", "land-grass", "land-park", "land-garden", "land-vegetation"}
)
# Piers and dams are drawn in the land colour, not the water colour.
LAND_COLOURED_WATER_LAYERS = frozenset({"water-dam-area", "water-pier-area", "water-pier"})
# VersaTiles' land cover (ADR 0021) is a second vector source drawn under OSM: one copy of each of
# the style's land fills, and of the water fill, reading its one layer. Opaque to z12, where its
# z10 outlines grow coarse, then faded to 25 % by z14: OSM's own fills draw on top wherever OSM has
# them, and land OSM does not map keeps a hint of colour. VersaTiles' recipe
# (github.com/versatiles-org/landcover-vectors, "Using it with OSM").
LANDCOVER_SOURCE = "landcover"
LANDCOVER_OPACITY = ["interpolate", ["linear"], ["zoom"], 12, 1, 14, 0.25]
LANDCOVER_SLOT = "slot-below-fills"

# Top-level keys that would switch on 3D terrain or a globe, which the package does not use.
DROPPED_KEYS = ("terrain", "sky", "projection")
RGBA_ALPHA = re.compile(r"^rgba\(\s*[0-9.]+\s*,\s*[0-9.]+\s*,\s*[0-9.]+\s*,\s*([0-9.]+)\s*\)$")


@dataclass(frozen=True)
class Palette:
    """The four colours the default style takes from the package's palette, as `#RRGGBB`.

    The hillshade colours replace VersaTiles' where a style needs softer relief; `None` keeps them.
    """

    name: str
    base: str
    green: str
    water: str
    road: str
    hillshade_highlight: str | None = None
    hillshade_shadow: str | None = None


LIGHT = Palette("default-light", base="#EEF2F7", green="#D0EEE9", water="#C1E5F6", road="#FFFFFF")
# On the dark base VersaTiles' white highlight and black shadow read as a strong relief, so the
# dark style dims both; exaggeration and method stay VersaTiles'.
DARK = Palette(
    "default-dark",
    base="#191F28",
    green="#14282B",
    water="#122442",
    road="#2E343E",
    hillshade_highlight="rgba(255,255,255,0.4)",
    hillshade_shadow="rgba(0,0,0,0.6)",
)


def _strip_sprite_prefix(node: Any) -> Any:
    if isinstance(node, str):
        return node.removeprefix(SPRITE_PREFIX)
    if isinstance(node, list):
        return [_strip_sprite_prefix(item) for item in node]
    if isinstance(node, dict):
        return {key: _strip_sprite_prefix(value) for key, value in node.items()}
    return node


def _with_alpha_of(original: object, colour: str) -> str:
    """`colour` (`#RRGGBB`), as `rgba(…)` with the alpha of `original` when that is not opaque."""
    if isinstance(original, str) and (match := RGBA_ALPHA.match(original)):
        alpha = match.group(1)
        if float(alpha) != 1.0:
            red, green, blue = (int(colour[i : i + 2], 16) for i in (1, 3, 5))
            return f"rgba({red},{green},{blue},{alpha})"
    return colour


def _set_colour(layer: dict[str, Any], prop: str, colour: str) -> None:
    paint = layer.get("paint", {})
    if prop in paint:
        paint[prop] = _with_alpha_of(paint[prop], colour)


def _recolour(layer: dict[str, Any], palette: Palette) -> None:
    layer_id: str = layer["id"]
    kind: str = layer["type"]
    colour_property = {"fill": "fill-color", "line": "line-color"}.get(kind)
    if kind == "hillshade":
        paint = layer.setdefault("paint", {})
        if palette.hillshade_highlight is not None:
            paint["hillshade-highlight-color"] = palette.hillshade_highlight
        if palette.hillshade_shadow is not None:
            paint["hillshade-shadow-color"] = palette.hillshade_shadow
    elif layer_id == "background":
        _set_colour(layer, "background-color", palette.base)
    elif colour_property is None:
        return
    elif layer_id.startswith("water-"):
        water = palette.base if layer_id in LAND_COLOURED_WATER_LAYERS else palette.water
        _set_colour(layer, colour_property, water)
    elif layer_id in GREEN_LAYERS:
        _set_colour(layer, colour_property, palette.green)
    elif kind == "line" and _is_street_fill(layer_id):
        _set_colour(layer, colour_property, palette.road)


def _is_street_fill(layer_id: str) -> bool:
    """The road line of a street, not its outline, its `-bg` backing or a bridge casing."""
    if not layer_id.startswith(("street-", "bridge-street-")):
        return False
    return not layer_id.endswith((":outline", ":bridge", "-bg"))


def transform(style: dict[str, Any], palette: Palette) -> dict[str, Any]:
    """The default style for `palette`, derived from a VersaTiles muted terrain style."""
    result = _strip_sprite_prefix(copy.deepcopy(style))
    for key in DROPPED_KEYS:
        result.pop(key, None)

    result["sources"] = {
        SOURCE_NAMES[name]: {"type": source["type"], "tiles": [PLACEHOLDER_URL]}
        for name, source in result["sources"].items()
    }
    result["glyphs"] = "maqs://glyphs"
    result["sprite"] = "maqs://sprite"

    metadata = result.setdefault("metadata", {})
    licence = metadata.get("license")
    if isinstance(licence, str) and licence.startswith("http"):
        # A note, not a bare URL: nothing in the shipped style may look like a remote resource.
        metadata["license"] = f"CC0-1.0, {licence}"
    metadata["maqs:style"] = palette.name

    for layer in result["layers"]:
        if "source" in layer:
            layer["source"] = SOURCE_NAMES[layer["source"]]
        layout = layer.get("layout", {})
        if "text-field" in layout and layout.get("text-font") != [BOLD_STACK]:
            layout["text-font"] = [REGULAR_STACK]
        if layer["id"].startswith("poi-"):
            layer["metadata"] = {"maqs:poi-key": layer["id"].removeprefix("poi-")}
            layer["layout"] = {**layout, "visibility": "none"}
        _recolour(layer, palette)

    result["sources"][LANDCOVER_SOURCE] = {"type": "vector", "tiles": [PLACEHOLDER_URL]}
    twins = [_landcover_twin(layer) for layer in result["layers"] if _has_landcover_twin(layer)]
    slot = next(
        (i for i, layer in enumerate(result["layers"]) if layer["id"] == LANDCOVER_SLOT), None
    )
    if slot is None:
        raise ValueError(f"the style has no {LANDCOVER_SLOT} layer to put the land cover above")
    result["layers"][slot + 1 : slot + 1] = twins
    return result


def _has_landcover_twin(layer: dict[str, Any]) -> bool:
    """A land fill, or the water fill: the kinds VersaTiles' land cover carries."""
    return layer.get("type") == "fill" and (
        layer["id"].startswith("land-") or layer["id"] == "water-area"
    )


def _landcover_twin(layer: dict[str, Any]) -> dict[str, Any]:
    twin = copy.deepcopy(layer)
    twin["id"] = f"landcover-{layer['id']}"
    twin["source"] = LANDCOVER_SOURCE
    twin["source-layer"] = LANDCOVER_SOURCE
    twin.pop("minzoom", None)
    twin.pop("maxzoom", None)
    twin.setdefault("paint", {})["fill-opacity"] = LANDCOVER_OPACITY
    return twin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write the default light and dark map styles.")
    parser.add_argument("styles_dir", type=Path, help="the extracted VersaTiles styles.tar.gz")
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for folder, palette in (("muted-terrain", LIGHT), ("muted-dark-terrain", DARK)):
        source = json.loads((args.styles_dir / folder / "style.json").read_text(encoding="utf-8"))
        text = json.dumps(transform(source, palette), indent=1, sort_keys=False) + "\n"
        (args.out_dir / f"{palette.name}.json").write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
