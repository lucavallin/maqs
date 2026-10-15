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
# `maqs build --region` keywords; a region or base pack with one of these ids could not be named.
RESERVED_IDS = frozenset({"all", "base"})
SUPPORTED_SCHEMA_VERSION = 1
DEFAULT_CONFIG_PATH = Path("config/regions.yaml")
DEFAULT_HIGHWAYS: tuple[str, ...] = (
    "motorway",
    "trunk",
    "primary",
    "secondary",
    "tertiary",
    "unclassified",
    "motorway_link",
    "trunk_link",
    "primary_link",
    "secondary_link",
    "tertiary_link",
)
DEFAULT_EXCLUDE_SURFACES: tuple[str, ...] = (
    "gravel",
    "dirt",
    "ground",
    "grass",
    "sand",
    "unpaved",
    "compacted",
    "fine_gravel",
    "mud",
    "earth",
    "wood",
    "pebblestone",
)
KNOWN_TRAIL_SOURCES = frozenset({"osm"})
EXPECT_KEYS = frozenset({"trails", "places", "curvature_segments"})


class ConfigError(ValueError):
    """The configuration file is invalid; the message says what and where."""


@dataclass(frozen=True)
class CurvatureConfig:
    highways: tuple[str, ...]
    exclude_surfaces: tuple[str, ...]


@dataclass(frozen=True)
class RowRange:
    min: int
    max: int


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
    trail_sources: tuple[str, ...]
    expect: dict[str, RowRange]


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
    curvature: CurvatureConfig

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


def _check_id(kind: str, value: object) -> str:
    if not isinstance(value, str) or not ID_RE.match(value):
        raise ConfigError(f"{kind} id {value!r} must match {ID_RE.pattern}")
    if value in RESERVED_IDS:
        raise ConfigError(f"{kind} id '{value}' is reserved")
    return value


def _is_int(value: object) -> bool:
    """True for an integer; YAML booleans are ints in Python and are rejected."""
    return isinstance(value, int) and not isinstance(value, bool)


def _entries(data: dict, key: str) -> list[dict]:
    raw = data.get(key)
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ConfigError(f"{key} must be a list")
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise ConfigError(f"{key}[{index}] must be a mapping, got {entry!r}")
    return raw


def _string_list(raw: object, where: str) -> tuple[str, ...]:
    if not isinstance(raw, list) or not all(isinstance(s, str) for s in raw):
        raise ConfigError(f"{where} must be a list of strings")
    return tuple(raw)


def _parse_curvature(raw: object) -> CurvatureConfig:
    if raw is None:
        return CurvatureConfig(DEFAULT_HIGHWAYS, DEFAULT_EXCLUDE_SURFACES)
    if not isinstance(raw, dict):
        raise ConfigError("curvature must be a mapping")
    highways = (
        _string_list(raw["highways"], "curvature.highways")
        if "highways" in raw
        else DEFAULT_HIGHWAYS
    )
    surfaces = (
        _string_list(raw["exclude_surfaces"], "curvature.exclude_surfaces")
        if "exclude_surfaces" in raw
        else DEFAULT_EXCLUDE_SURFACES
    )
    return CurvatureConfig(highways, surfaces)


def _parse_trail_sources(raw: object, where: str) -> tuple[str, ...]:
    if raw is None:
        return ("osm",)
    if not isinstance(raw, dict):
        raise ConfigError(f"{where}: trails must be a mapping")
    sources = raw.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ConfigError(f"{where}: trails.sources must list at least one source")
    for source in sources:
        if source not in KNOWN_TRAIL_SOURCES:
            raise ConfigError(
                f"{where}: unknown trail source {source!r}; known: {sorted(KNOWN_TRAIL_SOURCES)}"
            )
    return tuple(sources)


def _parse_expect(raw: object, where: str) -> dict[str, RowRange]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ConfigError(f"{where}: expect must be a mapping")
    out: dict[str, RowRange] = {}
    for key, value in raw.items():
        if key not in EXPECT_KEYS:
            raise ConfigError(f"{where}: unknown expect key {key!r}; known: {sorted(EXPECT_KEYS)}")
        if not isinstance(value, list) or len(value) != 2 or not all(_is_int(v) for v in value):
            raise ConfigError(f"{where}: expect.{key} must be [min, max]")
        low, high = value
        if low < 0:
            raise ConfigError(f"{where}: expect.{key}: min must be >= 0")
        if low > high:
            raise ConfigError(f"{where}: expect.{key}: min must be <= max")
        out[key] = RowRange(low, high)
    return out


def _parse_region(raw: dict) -> Region:
    rid = _check_id("region", raw.get("id"))
    where = f"region '{rid}'"
    name = raw.get("name")
    if not isinstance(name, dict) or not {"it", "en"} <= set(name):
        raise ConfigError(f"{where}: name must have 'it' and 'en'")
    hd = raw.get("hd_max_zoom")
    if hd is not None and (not _is_int(hd) or hd < 13):
        raise ConfigError(f"{where}: hd_max_zoom must be an integer >= 13")
    border = raw.get("bbox_border", 1)
    if not _is_int(border) or border < 0:
        raise ConfigError(f"{where}: bbox_border must be an integer >= 0")
    fixture = raw.get("fixture", False)
    if not isinstance(fixture, bool):
        raise ConfigError(f"{where}: fixture must be true or false, got {fixture!r}")
    return Region(
        id=rid,
        name={k: str(v) for k, v in name.items()},
        bbox=_parse_bbox(raw.get("bbox"), where),
        osm=raw.get("osm"),
        clip=raw.get("clip"),
        fixture=fixture,
        hd_max_zoom=hd,
        bbox_border=border,
        trail_sources=_parse_trail_sources(raw.get("trails"), where),
        expect=_parse_expect(raw.get("expect"), where),
    )


def _parse_base_pack(raw: dict, regions: dict[str, Region]) -> BasePack:
    pid = _check_id("base pack", raw.get("id"))
    names = raw.get("regions")
    if not isinstance(names, list) or not names:
        raise ConfigError(f"base pack '{pid}' must list at least one region")
    for n in names:
        if not isinstance(n, str):
            raise ConfigError(f"base pack '{pid}': regions must be region ids, got {n!r}")
        if n not in regions:
            raise ConfigError(f"base pack '{pid}' names unknown region '{n}'")
        if regions[n].fixture:
            raise ConfigError(f"base pack '{pid}' names fixture region '{n}'")
    max_zoom = raw.get("max_zoom", 10)
    if not _is_int(max_zoom) or not 0 <= max_zoom <= 14:
        raise ConfigError(f"base pack '{pid}': max_zoom must be an integer in 0..14")
    return BasePack(id=pid, regions=tuple(names), max_zoom=max_zoom)


def load_config(path: Path) -> Config:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path}: invalid YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: top level must be a mapping")
    version = data.get("schema_version")
    if version != SUPPORTED_SCHEMA_VERSION:
        raise ConfigError(
            f"schema_version {version} is not supported (expected {SUPPORTED_SCHEMA_VERSION})"
        )
    hd_default = data.get("hd_max_zoom", 13)
    if not _is_int(hd_default) or hd_default < 13:
        raise ConfigError("hd_max_zoom must be an integer >= 13")
    regions: dict[str, Region] = {}
    for raw in _entries(data, "regions"):
        region = _parse_region(raw)
        if region.id in regions:
            raise ConfigError(f"duplicate region id '{region.id}'")
        regions[region.id] = region
    if not regions:
        raise ConfigError("at least one region is required")
    packs = tuple(_parse_base_pack(raw, regions) for raw in _entries(data, "base_packs"))
    if len({p.id for p in packs}) != len(packs):
        raise ConfigError("duplicate base pack id")
    return Config(
        schema_version=version,
        hd_max_zoom=hd_default,
        base_packs=packs,
        regions=tuple(regions.values()),
        curvature=_parse_curvature(data.get("curvature")),
    )
