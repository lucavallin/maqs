"""Optional high-resolution terrain (z13+) from Mapterhorn's zoom-6 regional archives.

VersaTiles only hosts the planet at z0-12; Mapterhorn publishes z13-17 per zoom-6 tile as
`6-<x>-<y>.pmtiles`. Coverage is partial, so each archive is dry-run first and skipped
when it holds no tiles for the bbox. Opt-in: z14 for Veneto is ~1 GB (ADR 0001).
"""

from __future__ import annotations

import math
import re
from pathlib import Path

from maqs import tools
from maqs.config import Bbox
from maqs.context import BuildContext
from maqs.steps.tiles import format_bbox
from maqs.tools import ToolError
from maqs.validate import Expectation

MAPTERHORN_BASE = "https://download.mapterhorn.com"
HD_MIN_ZOOM = 13
_DRY_RUN_RE = re.compile(r"fetching (\d+) tiles")


def _tile_x(lon: float, z: int) -> int:
    return int(math.floor((lon + 180.0) / 360.0 * (1 << z)))


def _tile_y(lat: float, z: int) -> int:
    rad = math.radians(lat)
    return int(
        math.floor((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * (1 << z))
    )


def z6_tiles(bbox: Bbox) -> list[tuple[int, int]]:
    lon_min, lat_min, lon_max, lat_max = bbox
    xs = range(_tile_x(lon_min, 6), _tile_x(lon_max, 6) + 1)
    ys = range(_tile_y(lat_max, 6), _tile_y(lat_min, 6) + 1)
    return sorted((x, y) for x in xs for y in ys)


def archive_url(x: int, y: int) -> str:
    return f"{MAPTERHORN_BASE}/6-{x}-{y}.pmtiles"


def parse_dry_run_tiles(output: str) -> int | None:
    match = _DRY_RUN_RE.search(output)
    return int(match.group(1)) if match else None


class TerrainHDStep:
    name = "terrain-hd"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-terrain-hd.pmtiles"]

    def max_zoom(self, ctx: BuildContext) -> int:
        assert ctx.region is not None
        return ctx.region.hd_max_zoom or ctx.config.hd_max_zoom

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(
            HD_MIN_ZOOM, self.max_zoom(ctx), frozenset({"webp", "png"}), source=MAPTERHORN_BASE
        )

    def _extract_argv(
        self, url: str, part: Path, bbox: Bbox, max_zoom: int, dry_run: bool
    ) -> list[str]:
        argv = [
            str(tools.find_tool("pmtiles")),
            "extract",
            url,
            str(part),
            f"--bbox={format_bbox(bbox)}",
            f"--minzoom={HD_MIN_ZOOM}",
            f"--maxzoom={max_zoom}",
        ]
        return [*argv, "--dry-run"] if dry_run else argv

    def build(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        bbox, max_zoom = ctx.region.bbox, self.max_zoom(ctx)
        out = self.outputs(ctx)[0]
        parts: list[tuple[str, Path]] = []
        merged = out.with_name(out.name + ".part-merged")
        try:
            for x, y in z6_tiles(bbox):
                url = archive_url(x, y)
                part = out.with_name(f"{out.name}.part-{x}-{y}")
                dry_argv = self._extract_argv(url, part, bbox, max_zoom, dry_run=True)
                probe = tools.run(dry_argv)
                text = (probe.stderr or "") + (probe.stdout or "")
                tiles = parse_dry_run_tiles(text)
                if tiles is None:
                    raise ToolError(
                        dry_argv,
                        1,
                        "could not read the tile count from pmtiles extract --dry-run output: "
                        + text.strip()[-200:],
                    )
                if tiles == 0:
                    continue
                tools.run(self._extract_argv(url, part, bbox, max_zoom, dry_run=False))
                parts.append((url, part))
            if not parts:
                raise ToolError(
                    ["pmtiles", "extract"], 1, f"no high-resolution terrain tiles cover {ctx.label}"
                )
            if len(parts) == 1:
                url, part = parts[0]
                part.replace(out)
                return self._extract_argv(url, out, bbox, max_zoom, dry_run=False)
            argv = [
                str(tools.find_tool("pmtiles")),
                "merge",
                *(str(part) for _, part in parts),
                str(merged),
            ]
            tools.run(argv)
            merged.replace(out)
            return argv
        finally:
            for _, part in parts:
                part.unlink(missing_ok=True)
            merged.unlink(missing_ok=True)
