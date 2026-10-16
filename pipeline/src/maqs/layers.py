"""Layer names, their schema versions and the versioned output file names."""

from __future__ import annotations

from maqs.sqlite_out import SCHEMA_VERSION

STANDARD_LAYERS: tuple[str, ...] = ("basemap", "terrain", "trails", "places", "curvature")

# Tile layers, version 1: basemap is Shortbread 1.0 gzip MVT z0-14; terrain is terrarium WebP 512 px
# z0-12; terrain-hd is terrarium z13 to hd_max_zoom (regions.yaml), WebP or PNG as Mapterhorn stores
# it. A change in encoding, zoom range or schema bumps the number (docs/data-format.md).
TILE_SCHEMA_VERSION: dict[str, int] = {"basemap": 1, "terrain": 1, "terrain-hd": 1}

LAYER_SCHEMA_VERSION: dict[str, int] = {**TILE_SCHEMA_VERSION, **SCHEMA_VERSION}


def output_name(label: str, layer: str, ext: str) -> str:
    """`<label>-<layer>.v<N>.<ext>`: two schema versions of one layer can share a release."""
    return f"{label}-{layer}.v{LAYER_SCHEMA_VERSION[layer]}.{ext}"
