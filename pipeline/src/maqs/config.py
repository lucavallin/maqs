"""Loads and validates config/regions.yaml.

A region is the smallest unit a pack is cut at. Base packs are named lists of regions
bundled inside apps. Nothing here is Italy-specific: a region anywhere is one entry.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import yaml

Bbox = tuple[float, float, float, float]

ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SUPPORTED_SCHEMA_VERSION = 1
DEFAULT_CONFIG_PATH = Path("config/regions.yaml")


class ConfigError(ValueError):
    """The configuration file is invalid; the message says what and where."""


@dataclass(frozen=True)
class Region:
    id: str
    name: dict[str, str]
    bbox: Bbox
    osm: dict[str, str] | None
    clip: dict | None
    fixture: bool
    hd_max_zoom: int | None
    bbox_border: int


@dataclass(frozen=True)
class BasePack:
    id: str
    regions: tuple[str, ...]
    max_zoom: int


@dataclass(frozen=True)
class Config:
    schema_version: int
    hd_max_zoom: int
    base_packs: tuple[BasePack, ...]
    regions: tuple[Region, ...]

    def region(self, region_id: str) -> Region:
        for r in self.regions:
            if r.id == region_id:
                return r
        raise KeyError(region_id)

    def base_pack(self, pack_id: str) -> BasePack:
        for p in self.base_packs:
            if p.id == pack_id:
                return p
        raise KeyError(pack_id)

    def base_pack_bbox(self, pack: BasePack) -> Bbox:
        return union_bbox(self.region(rid).bbox for rid in pack.regions)

    def geofabrik_extracts(self) -> list[str]:
        seen: list[str] = []
        for r in self.regions:
            if r.osm and r.osm.get("geofabrik") and r.osm["geofabrik"] not in seen:
                seen.append(r.osm["geofabrik"])
        return seen

    def region_ids(self, include_fixtures: bool) -> list[str]:
        return [r.id for r in self.regions if include_fixtures or not r.fixture]


def union_bbox(bboxes: Iterable[Bbox]) -> Bbox:
    boxes = list(bboxes)
    if not boxes:
        raise ConfigError("union of zero bboxes")
    return (
        min(b[0] for b in boxes),
        min(b[1] for b in boxes),
        max(b[2] for b in boxes),
        max(b[3] for b in boxes),
    )


def _parse_bbox(raw: object, where: str) -> Bbox:
    if not isinstance(raw, list) or len(raw) != 4:
        raise ConfigError(f"{where}: bbox must have 4 numbers, got {raw!r}")
    try:
        lon_min, lat_min, lon_max, lat_max = (float(v) for v in raw)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{where}: bbox must have 4 numbers, got {raw!r}") from exc
    for lon in (lon_min, lon_max):
        if not -180.0 <= lon <= 180.0:
            raise ConfigError(f"{where}: longitude out of range: {lon}")
    for lat in (lat_min, lat_max):
        if not -90.0 <= lat <= 90.0:
            raise ConfigError(f"{where}: latitude out of range: {lat}")
    if lon_min >= lon_max:
        raise ConfigError(
            f"{where}: lon_min must be < lon_max (antimeridian-crossing boxes are not supported)"
        )
    if lat_min >= lat_max:
        raise ConfigError(f"{where}: lat_min must be < lat_max")
    return (lon_min, lat_min, lon_max, lat_max)


def _parse_region(raw: dict) -> Region:
    rid = raw.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise ConfigError(f"region id {rid!r} must match {ID_RE.pattern}")
    where = f"region '{rid}'"
    name = raw.get("name")
    if not isinstance(name, dict) or not {"it", "en"} <= set(name):
        raise ConfigError(f"{where}: name must have 'it' and 'en'")
    hd = raw.get("hd_max_zoom")
    if hd is not None and (not isinstance(hd, int) or hd < 13):
        raise ConfigError(f"{where}: hd_max_zoom must be an integer >= 13")
    border = raw.get("bbox_border", 1)
    if isinstance(border, bool) or not isinstance(border, int) or border < 0:
        raise ConfigError(f"{where}: bbox_border must be an integer >= 0")
    return Region(
        id=rid,
        name={k: str(v) for k, v in name.items()},
        bbox=_parse_bbox(raw.get("bbox"), where),
        osm=raw.get("osm"),
        clip=raw.get("clip"),
        fixture=bool(raw.get("fixture", False)),
        hd_max_zoom=hd,
        bbox_border=border,
    )


def _parse_base_pack(raw: dict, regions: dict[str, Region]) -> BasePack:
    pid = raw.get("id")
    if not isinstance(pid, str) or not ID_RE.match(pid):
        raise ConfigError(f"base pack id {pid!r} must match {ID_RE.pattern}")
    names = raw.get("regions")
    if not isinstance(names, list) or not names:
        raise ConfigError(f"base pack '{pid}' must list at least one region")
    for n in names:
        if n not in regions:
            raise ConfigError(f"base pack '{pid}' names unknown region '{n}'")
        if regions[n].fixture:
            raise ConfigError(f"base pack '{pid}' names fixture region '{n}'")
    max_zoom = raw.get("max_zoom", 10)
    if not isinstance(max_zoom, int) or not 0 <= max_zoom <= 14:
        raise ConfigError(f"base pack '{pid}': max_zoom must be an integer in 0..14")
    return BasePack(id=pid, regions=tuple(names), max_zoom=max_zoom)


def load_config(path: Path) -> Config:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: top level must be a mapping")
    version = data.get("schema_version")
    if version != SUPPORTED_SCHEMA_VERSION:
        raise ConfigError(
            f"schema_version {version} is not supported (expected {SUPPORTED_SCHEMA_VERSION})"
        )
    hd_default = data.get("hd_max_zoom", 13)
    if not isinstance(hd_default, int) or hd_default < 13:
        raise ConfigError("hd_max_zoom must be an integer >= 13")
    regions: dict[str, Region] = {}
    for raw in data.get("regions") or []:
        region = _parse_region(raw)
        if region.id in regions:
            raise ConfigError(f"duplicate region id '{region.id}'")
        regions[region.id] = region
    if not regions:
        raise ConfigError("at least one region is required")
    packs = tuple(_parse_base_pack(raw, regions) for raw in data.get("base_packs") or [])
    if len({p.id for p in packs}) != len(packs):
        raise ConfigError("duplicate base pack id")
    return Config(
        schema_version=version,
        hd_max_zoom=hd_default,
        base_packs=packs,
        regions=tuple(regions.values()),
    )
