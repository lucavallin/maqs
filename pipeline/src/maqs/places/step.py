"""The places layer: peaks, passes, huts, shelters and named settlements with a label rank."""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

import osmium

from maqs.context import BuildContext
from maqs.osm import extract
from maqs.overlay import build_overlay
from maqs.sqlite_out import COUNT_TABLES, TABLES, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.steps.data import metadata_for
from maqs.validate import Expectation, SqliteExpectation

PLACE_FILTERS: tuple[str, ...] = (
    "n/natural=peak,volcano,saddle",
    "n/mountain_pass=yes",
    "n/tourism=alpine_hut,wilderness_hut",
    "n/amenity=shelter",
    "n/place=village,hamlet,isolated_dwelling",
)
KINDS: tuple[str, ...] = (
    "peak",
    "volcano",
    "saddle",
    "pass",
    "alpine_hut",
    "wilderness_hut",
    "shelter",
    "village",
    "hamlet",
    "isolated_dwelling",
)
PLACES_MIN_ZOOM = 8
PLACES_MAX_ZOOM = 14
_ELE_RE = re.compile(r"^\s*(-?\d+(?:[.,]\d+)?)\s*(?:m|meters|metres)?\s*$", re.IGNORECASE)


def place_kind(tags: Mapping[str, str]) -> str | None:
    """The place kind for a node's tags, or None when it is not a place we keep."""
    if tags.get("mountain_pass") == "yes":
        return "pass"
    natural = tags.get("natural")
    if natural in ("peak", "volcano", "saddle"):
        return natural
    tourism = tags.get("tourism")
    if tourism in ("alpine_hut", "wilderness_hut"):
        return tourism
    if tags.get("amenity") == "shelter":
        return "shelter"
    place = tags.get("place")
    if place in ("village", "hamlet", "isolated_dwelling") and tags.get("name"):
        return place
    return None


def parse_ele(value: str | None) -> tuple[float | None, str | None]:
    """Parse an OSM `ele` value in metres; returns (value, problem)."""
    if value is None:
        return None, None
    match = _ELE_RE.match(value)
    if not match:
        return None, f"unparsable ele {value!r}"
    number = match.group(1)
    if "," in number and "." not in number:
        # "1,763" groups thousands; "1,5" is a decimal comma.
        grouped = len(number.split(",")[-1]) == 3
        number = number.replace(",", "" if grouped else ".")
    return float(number), None


def rank_score(wikidata: str | None, ele: float | None) -> float:
    """Label priority: a wikidata tag counts as 1000 m of elevation (docs/data-format.md)."""
    return 1000.0 * (1 if wikidata else 0) + (ele or 0.0)


@dataclass
class PlaceRecord:
    osm_id: int
    kind: str
    name: str | None
    name_it: str | None
    name_de: str | None
    name_fur: str | None
    name_sl: str | None
    ele: float | None
    wikidata: str | None
    lon: float
    lat: float
    rank_score: float
    anomalies: list[Anomaly] = field(default_factory=list)


def read_places(pbf: Path) -> list[PlaceRecord]:
    records: list[PlaceRecord] = []
    for node in osmium.FileProcessor(str(pbf), osmium.osm.NODE):
        tags = dict(node.tags)
        kind = place_kind(tags)
        if kind is None or not node.location.valid():
            continue
        ele, problem = parse_ele(tags.get("ele"))
        anomalies = [Anomaly("ele", f"node/{node.id}", problem)] if problem else []
        wikidata = tags.get("wikidata")
        records.append(
            PlaceRecord(
                node.id,
                kind,
                tags.get("name"),
                tags.get("name:it"),
                tags.get("name:de"),
                tags.get("name:fur"),
                tags.get("name:sl"),
                ele,
                wikidata,
                node.location.lon,
                node.location.lat,
                rank_score(wikidata, ele),
                anomalies,
            )
        )
    return records


def place_feature(record: PlaceRecord, place_id: int) -> dict:
    properties = {
        "id": place_id,
        "kind": record.kind,
        "name": record.name,
        "ele": record.ele,
        "rank_score": record.rank_score,
    }
    geometry = {"type": "Point", "coordinates": [record.lon, record.lat]}
    return {"type": "Feature", "properties": properties, "geometry": geometry}


class PlacesStep:
    name = "places"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [
            ctx.out_dir / f"{ctx.label}-places.sqlite",
            ctx.out_dir / f"{ctx.label}-places.pmtiles",
        ]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx.require_region()
        if output.suffix == ".sqlite":
            ranges = {"places": region.expect["places"]} if "places" in region.expect else {}
            return SqliteExpectation(
                "places", region.id, TABLES["places"], COUNT_TABLES["places"], ranges
            )
        return Expectation(PLACES_MIN_ZOOM, PLACES_MAX_ZOOM, frozenset({"mvt"}))

    def build(self, ctx: BuildContext) -> StepOutcome:
        filtered = extract.filtered_region_pbf(ctx, "places", PLACE_FILTERS)
        meta = metadata_for(ctx, "places")
        records = read_places(filtered)
        anomalies = [a for r in records for a in r.anomalies]
        sqlite_path, overlay_path = self.outputs(ctx)

        def fill(conn: sqlite3.Connection) -> None:
            for index, r in enumerate(records):
                place_id = index + 1
                row = (
                    place_id,
                    "node",
                    r.osm_id,
                    r.kind,
                    r.name,
                    r.name_it,
                    r.name_de,
                    r.name_fur,
                    r.name_sl,
                    r.ele,
                    r.wikidata,
                    r.lon,
                    r.lat,
                    r.rank_score,
                )
                conn.execute(f"INSERT INTO places VALUES ({','.join('?' * len(row))})", row)
                conn.execute(
                    "INSERT INTO places_rtree VALUES (?, ?, ?, ?, ?)",
                    (place_id, r.lon, r.lon, r.lat, r.lat),
                )

        write_sqlite(sqlite_path, "places", meta, fill)
        features = (place_feature(r, i + 1) for i, r in enumerate(records))
        argv = build_overlay(features, overlay_path, "places", PLACES_MIN_ZOOM, PLACES_MAX_ZOOM)
        return StepOutcome(argv, anomalies)
