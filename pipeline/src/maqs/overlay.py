"""tippecanoe overlays: GeoJSONSeq in, gzip MVT PMTiles out."""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from pathlib import Path

from maqs import tools


def tippecanoe_argv(
    src: Path,
    out: Path,
    layer: str,
    min_zoom: int,
    max_zoom: int,
    extra: Sequence[str] = (),
) -> list[str]:
    """The tippecanoe command; `extra` flags go before the input file."""
    return [
        str(tools.find_tool("tippecanoe")),
        "-o",
        str(out),
        "-f",
        "-q",
        "-l",
        layer,
        f"-Z{min_zoom}",
        f"-z{max_zoom}",
        *extra,
        str(src),
    ]


def write_geojsonseq(features: Iterable[dict], path: Path) -> int:
    count = 0
    with path.open("w", encoding="utf-8") as f:
        for feature in features:
            f.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
    return count


def build_overlay(
    features: Iterable[dict],
    out: Path,
    layer: str,
    min_zoom: int,
    max_zoom: int,
    extra: Sequence[str] = (),
) -> list[str]:
    """Write the features next to `out`, run tippecanoe, and return the command it ran."""
    src = out.with_suffix(".geojsonseq")
    try:
        write_geojsonseq(features, src)
        argv = tippecanoe_argv(src, out, layer, min_zoom, max_zoom, extra)
        tools.run(argv)
    finally:
        src.unlink(missing_ok=True)
    return argv
