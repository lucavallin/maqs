"""Tile layers cut from the VersaTiles planet archives by remote range requests (ADR 0004).

Basemap and base packs are recompressed to gzip because MapLibre Native rejects brotli
PMTiles; the elevation archive is already uncompressed WebP and is left untouched.
"""

from __future__ import annotations

from pathlib import Path

from maqs import tools
from maqs.config import Bbox
from maqs.context import BuildContext
from maqs.validate import BASE_PACK_CAP, Expectation

OSM_SOURCE = "https://download.versatiles.org/osm-landcover.versatiles"
ELEVATION_SOURCE = "https://download.versatiles.org/elevation.versatiles"
BASEMAP_MAX_ZOOM = 14
TERRAIN_MAX_ZOOM = 12


def format_bbox(bbox: Bbox) -> str:
    return ",".join(f"{v:.7f}".rstrip("0").rstrip(".") for v in bbox)


class _VersatilesStep:
    name = "tiles"
    suffix = ""

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-{self.suffix}.pmtiles"]

    def argv(self, ctx: BuildContext) -> list[str]:
        raise NotImplementedError

    def build(self, ctx: BuildContext) -> list[str]:
        argv = self.argv(ctx)
        tools.run(argv)
        return argv


class BasemapStep(_VersatilesStep):
    name = "basemap"
    suffix = "basemap"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        return [
            str(tools.find_tool("versatiles")),
            "convert",
            "--bbox",
            format_bbox(ctx.region.bbox),
            "--bbox-border",
            "1",
            "--compress",
            "gzip",
            OSM_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(0, BASEMAP_MAX_ZOOM, frozenset({"mvt", "mlt"}))


class TerrainStep(_VersatilesStep):
    name = "terrain"
    suffix = "terrain"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        return [
            str(tools.find_tool("versatiles")),
            "convert",
            "--bbox",
            format_bbox(ctx.region.bbox),
            "--bbox-border",
            "1",
            "--max-zoom",
            str(TERRAIN_MAX_ZOOM),
            ELEVATION_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(0, TERRAIN_MAX_ZOOM, frozenset({"webp", "png"}))


class BasePackStep(_VersatilesStep):
    name = "base"
    suffix = "basemap"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.base_pack is not None
        bbox = ctx.config.base_pack_bbox(ctx.base_pack)
        return [
            str(tools.find_tool("versatiles")),
            "convert",
            "--bbox",
            format_bbox(bbox),
            "--max-zoom",
            str(ctx.base_pack.max_zoom),
            "--compress",
            "gzip",
            OSM_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        assert ctx.base_pack is not None
        return Expectation(
            0, ctx.base_pack.max_zoom, frozenset({"mvt", "mlt"}), size_cap=BASE_PACK_CAP
        )


TILE_STEPS: dict[str, type[_VersatilesStep]] = {"basemap": BasemapStep, "terrain": TerrainStep}
