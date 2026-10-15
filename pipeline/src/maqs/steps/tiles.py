"""Tile layers cut from the VersaTiles planet archives by remote range requests (ADR 0004).

Basemap and base packs are recompressed to gzip because MapLibre Native rejects brotli
PMTiles; the elevation archive is already uncompressed WebP and is left untouched.
"""

from __future__ import annotations

from pathlib import Path

from maqs import tools
from maqs.config import BasePack, Bbox, Region
from maqs.context import BuildContext
from maqs.steps.base import StepOutcome
from maqs.validate import BASE_PACK_CAP, Expectation

OSM_SOURCE = "https://download.versatiles.org/osm-landcover.versatiles"
ELEVATION_SOURCE = "https://download.versatiles.org/elevation.versatiles"
BASEMAP_MAX_ZOOM = 14
TERRAIN_MAX_ZOOM = 12


def format_bbox(bbox: Bbox) -> str:
    return ",".join(f"{v:.7f}".rstrip("0").rstrip(".") for v in bbox)


def _border_args(region: Region) -> list[str]:
    """`--bbox-border N` when the region asks for a tile ring; nothing for a border of 0."""
    return ["--bbox-border", str(region.bbox_border)] if region.bbox_border > 0 else []


class _VersatilesStep:
    name = "tiles"
    suffix = ""

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-{self.suffix}.pmtiles"]

    def argv(self, ctx: BuildContext) -> list[str]:
        raise NotImplementedError

    def build(self, ctx: BuildContext) -> StepOutcome:
        argv = self.argv(ctx)
        tools.run(argv)
        return StepOutcome(argv)


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
            *_border_args(ctx.region),
            "--compress",
            "gzip",
            OSM_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation:
        return Expectation(0, BASEMAP_MAX_ZOOM, frozenset({"mvt"}), source=OSM_SOURCE)


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
            *_border_args(ctx.region),
            "--max-zoom",
            str(TERRAIN_MAX_ZOOM),
            ELEVATION_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation:
        return Expectation(0, TERRAIN_MAX_ZOOM, frozenset({"webp", "png"}), source=ELEVATION_SOURCE)


class BasePackStep(_VersatilesStep):
    """One base pack; every configured pack is one step of the single `base` target."""

    suffix = "basemap"

    def __init__(self, pack: BasePack) -> None:
        self.pack = pack
        self.name = f"base-{pack.id}"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{self.name}-{self.suffix}.pmtiles"]

    def argv(self, ctx: BuildContext) -> list[str]:
        bbox = ctx.config.base_pack_bbox(self.pack)
        return [
            str(tools.find_tool("versatiles")),
            "convert",
            "--bbox",
            format_bbox(bbox),
            "--max-zoom",
            str(self.pack.max_zoom),
            "--compress",
            "gzip",
            OSM_SOURCE,
            str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation:
        return Expectation(
            0, self.pack.max_zoom, frozenset({"mvt"}), size_cap=BASE_PACK_CAP, source=OSM_SOURCE
        )


TILE_STEPS: dict[str, type[_VersatilesStep]] = {"basemap": BasemapStep, "terrain": TerrainStep}
