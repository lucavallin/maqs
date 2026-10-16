"""Geofabrik input and the per-region osmium cuts every data layer reads.

The extract is downloaded once per run and never re-downloaded (delete it to refresh).
Hiking relations are completed across the clip boundary with osmium's smart strategy, so
a relation that crosses a region border keeps all its member ways (ADR 0006).
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from pathlib import Path

from maqs import tools
from maqs.cache import FetchError, download, md5_of, parse_md5_sidecar
from maqs.context import BuildContext
from maqs.steps.tiles import format_bbox

GEOFABRIK_BASE = "https://download.geofabrik.de"


def extract_name(extract: str) -> str:
    return extract.strip("/").replace("/", "-")


def region_extract_id(ctx: BuildContext) -> str:
    region = ctx.require_region()
    extract = (region.osm or {}).get("geofabrik")
    if not isinstance(extract, str) or not extract:
        raise FetchError(
            f"region '{region.id}' has no osm.geofabrik extract; the data layers need one"
        )
    return extract


def _osmium() -> str:
    return str(tools.find_tool("osmium"))


def fetch_extract(cache: Path, extract: str) -> Path:
    """Download `<extract>-latest.osm.pbf` into the cache, md5-verified; reuse when cached."""
    dest = cache / "geofabrik" / f"{extract_name(extract)}-latest.osm.pbf"
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{GEOFABRIK_BASE}/{extract}-latest.osm.pbf"
    md5_file = dest.with_suffix(dest.suffix + ".md5")
    download(f"{url}.md5", md5_file)
    expected = parse_md5_sidecar(md5_file.read_text(encoding="utf-8"))
    tmp = dest.with_suffix(dest.suffix + ".unverified")
    download(url, tmp)
    actual = md5_of(tmp)
    if actual != expected:
        tmp.unlink(missing_ok=True)
        md5_file.unlink(missing_ok=True)
        raise FetchError(f"md5 mismatch for {url}: expected {expected}, got {actual}")
    tmp.replace(dest)
    return dest


def geofabrik_pbf(ctx: BuildContext) -> Path:
    return fetch_extract(ctx.cache, region_extract_id(ctx))


def _partial_path(dst: Path) -> Path:
    """Where an osmium cut is written before it is renamed to `dst`.

    The name keeps the `.osm.pbf` suffix, from which osmium picks the output format.
    """
    return dst.with_name(dst.name.removesuffix(".osm.pbf") + ".tmp.osm.pbf")


def _run_into(argv: list[str], tmp: Path, dst: Path) -> None:
    """Run an osmium command that writes `tmp`, then rename it to `dst`.

    Callers reuse whatever exists at `dst`, so an interrupted or failed run must never leave a
    truncated file there.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        tools.run(argv)
        tmp.replace(dst)
    finally:
        tmp.unlink(missing_ok=True)


def tags_filter(src: Path, dst: Path, expressions: Sequence[str]) -> list[str]:
    tmp = _partial_path(dst)
    argv = [_osmium(), "tags-filter", str(src), *expressions, "-o", str(tmp), "--overwrite"]
    _run_into(argv, tmp, dst)
    return argv


def hiking_pbf(ctx: BuildContext) -> Path:
    src = geofabrik_pbf(ctx)
    dst = src.with_name(src.name.replace("-latest.osm.pbf", "-hiking.osm.pbf"))
    if dst.exists() and not ctx.force:
        return dst
    tags_filter(src, dst, ["r/route=hiking"])
    return dst


def _rings(feature: dict) -> list[tuple[list[list[float]], bool]]:
    geometry = feature.get("geometry") or {}
    kind = geometry.get("type")
    polygons: list[list[list[list[float]]]]
    if kind == "Polygon":
        polygons = [geometry["coordinates"]]
    elif kind == "MultiPolygon":
        polygons = geometry["coordinates"]
    else:
        return []
    return [(ring, i > 0) for polygon in polygons for i, ring in enumerate(polygon)]


def write_poly(features: Iterable[dict], path: Path, name: str) -> int:
    """Write an Osmosis .poly: one section per ring, '!' marks inner rings; returns the count."""
    lines = [name]
    count = 0
    for feature in features:
        for ring, inner in _rings(feature):
            count += 1
            lines.append(f"{'!' if inner else ''}ring{count}")
            lines.extend(f"   {lon!r} {lat!r}" for lon, lat in ring)
            lines.append("END")
    if count == 0:
        raise FetchError(f"{path}: the admin relations produced no polygon rings")
    lines.append("END")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return count


def clip_poly(ctx: BuildContext) -> Path | None:
    region = ctx.require_region()
    admin = (region.clip or {}).get("admin")
    if not admin:
        return None
    poly = ctx.cache / region.id / "clip.poly"
    if poly.exists() and not ctx.force:
        return poly
    src = geofabrik_pbf(ctx)
    admin_pbf = poly.with_name("admin.osm.pbf")
    seq = poly.with_name("admin.geojsonseq")
    poly.parent.mkdir(parents=True, exist_ok=True)
    osmium = _osmium()
    try:
        ids = [f"r{i}" for i in admin]
        tools.run(
            [
                osmium,
                "getid",
                "-r",
                "-t",
                str(src),
                *ids,
                "-o",
                str(admin_pbf),
                "-f",
                "pbf",
                "--overwrite",
            ]
        )
        tools.run(
            [osmium, "export", str(admin_pbf), "-f", "geojsonseq", "--geometry-types=polygon"]
            + ["-o", str(seq), "--overwrite"]
        )
        features = [
            json.loads(line.lstrip("\x1e"))
            for line in seq.read_text(encoding="utf-8").splitlines()
            if line.strip("\x1e \n")
        ]
        write_poly(features, poly, region.id)
    finally:
        admin_pbf.unlink(missing_ok=True)
        seq.unlink(missing_ok=True)
    return poly


def _extent_args(ctx: BuildContext) -> list[str]:
    poly = clip_poly(ctx)
    if poly is not None:
        return ["--polygon", str(poly)]
    return ["--bbox", format_bbox(ctx.require_region().bbox)]


def _cut(ctx: BuildContext, src: Path, dst: Path, strategy: Sequence[str]) -> None:
    tmp = _partial_path(dst)
    argv = [_osmium(), "extract", *_extent_args(ctx), *strategy, str(src), "-o", str(tmp)]
    _run_into([*argv, "--overwrite"], tmp, dst)


def region_pbf(ctx: BuildContext) -> Path:
    dst = ctx.cache / ctx.require_region().id / "region.osm.pbf"
    if dst.exists() and not ctx.force:
        return dst
    _cut(ctx, geofabrik_pbf(ctx), dst, ["-s", "complete_ways"])
    return dst


def region_hiking_pbf(ctx: BuildContext) -> Path:
    dst = ctx.cache / ctx.require_region().id / "hiking.osm.pbf"
    if dst.exists() and not ctx.force:
        return dst
    _cut(ctx, hiking_pbf(ctx), dst, ["-s", "smart", "-S", "types=route"])
    return dst


def filtered_region_pbf(ctx: BuildContext, name: str, expressions: Sequence[str]) -> Path:
    """The region cut narrowed by `osmium tags-filter`, cached as `<cache>/<region>/<name>.osm.pbf`.

    The cache key is the name alone: after changing the expressions, rebuild with --force.
    """
    dst = ctx.cache / ctx.require_region().id / f"{name}.osm.pbf"
    if dst.exists() and not ctx.force:
        return dst
    tags_filter(region_pbf(ctx), dst, expressions)
    return dst


def osm_timestamp(pbf: Path) -> str | None:
    header = "header.option.osmosis_replication_timestamp"
    result = tools.run([_osmium(), "fileinfo", "-g", header, str(pbf)])
    value = (result.stdout or "").strip()
    return value or None
