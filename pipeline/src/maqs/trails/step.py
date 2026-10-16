"""The trails layer: SQLite index plus a vector overlay, from the region's hiking extract."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from maqs.context import BuildContext
from maqs.geometry import encode_polyline
from maqs.layers import output_name
from maqs.osm import extract
from maqs.osm.terrain_sampler import TerrainSampler, ascent_descent
from maqs.overlay import build_overlay
from maqs.pmtiles_header import PMTilesError
from maqs.sqlite_out import COUNT_TABLES, TABLES, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.steps.data import metadata_for
from maqs.trails.merge import merge
from maqs.trails.model import TrailRecord
from maqs.trails.sources.osm import read_osm_trails
from maqs.validate import Expectation, SqliteExpectation

TRAILS_MIN_ZOOM = 6
TRAILS_MAX_ZOOM = 14
TRAILS_COLUMNS = 31


def trail_row(record: TrailRecord, trail_id: int, winner_id: int | None) -> tuple:
    bbox = record.bbox or (None, None, None, None)
    return (
        trail_id,
        record.source,
        record.source_id,
        record.source_licence,
        record.source_date,
        record.osm_type,
        record.osm_id,
        record.ref,
        record.ref_rei,
        record.name,
        record.difficulty,
        record.difficulty_scheme,
        record.difficulty_value,
        record.network,
        record.operator,
        record.osmc_symbol,
        record.from_name,
        record.to_name,
        record.roundtrip,
        record.survey_date,
        record.website,
        record.length_m,
        record.ascent_m,
        record.descent_m,
        *bbox,
        ";".join(encode_polyline(leg) for leg in record.legs),
        record.geometry_status,
        winner_id,
    )


def trail_feature(record: TrailRecord, trail_id: int) -> dict:
    legs = [[list(c) for c in leg] for leg in record.legs]
    if len(legs) == 1:
        geometry = {"type": "LineString", "coordinates": legs[0]}
    else:
        geometry = {"type": "MultiLineString", "coordinates": legs}
    properties = {
        "id": trail_id,
        "ref": record.ref,
        "name": record.name,
        "difficulty": record.difficulty,
        "network": record.network,
        "osmc_symbol": record.osmc_symbol,
    }
    return {"type": "Feature", "properties": properties, "geometry": geometry}


def _add_elevation(record: TrailRecord, sampler: TerrainSampler, anomalies: list[Anomaly]) -> None:
    """Sum ascent and descent per leg; NULL (never 0.0) when no sample had terrain coverage."""
    ascent: float | None = None
    descent: float | None = None
    missing = 0
    for leg in record.legs:
        up, down, gaps = ascent_descent(sampler, leg)
        missing += gaps
        if up is not None and down is not None:
            ascent = (ascent or 0.0) + up
            descent = (descent or 0.0) + down
    record.ascent_m, record.descent_m = ascent, descent
    if ascent is None:
        message = f"{missing} samples without a terrain tile"
        anomalies.append(Anomaly("terrain_no_coverage", record.source_id, message))
    elif missing:
        message = f"{missing} elevation samples had no terrain tile"
        anomalies.append(Anomaly("terrain_gap", record.source_id, message))


class TrailsStep:
    name = "trails"
    layer = "trails"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [
            ctx.out_dir / output_name(ctx.label, "trails", "sqlite"),
            ctx.out_dir / output_name(ctx.label, "trails", "pmtiles"),
        ]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx.require_region()
        if output.suffix == ".sqlite":
            ranges = {"trails": region.expect["trails"]} if "trails" in region.expect else {}
            return SqliteExpectation(
                "trails", region.id, TABLES["trails"], COUNT_TABLES["trails"], ranges
            )
        return Expectation(TRAILS_MIN_ZOOM, TRAILS_MAX_ZOOM, frozenset({"mvt"}))

    def build(self, ctx: BuildContext) -> StepOutcome:
        region = ctx.require_region()
        anomalies: list[Anomaly] = []
        hiking = extract.region_hiking_pbf(ctx)
        meta = metadata_for(ctx, "trails")
        per_source: list[tuple[str, list[TrailRecord]]] = []
        for source in region.trail_sources:
            if source == "osm":
                per_source.append(("osm", read_osm_trails(hiking, source_date=meta.osm_timestamp)))
        records = merge(per_source)
        terrain = ctx.out_dir / output_name(ctx.label, "terrain", "pmtiles")
        sampler: TerrainSampler | None = None
        unreadable = False
        if not terrain.exists():
            message = "no terrain archive in this build; ascent and descent are null"
            anomalies.append(Anomaly("terrain_missing", ctx.label, message))
        else:
            try:
                sampler = TerrainSampler(terrain)
            except PMTilesError as exc:
                unreadable = True
                anomalies.append(Anomaly("terrain_unreadable", terrain.name, str(exc)))
        for record in records:
            anomalies.extend(record.anomalies)
            if sampler is not None and not unreadable and record.legs:
                try:
                    _add_elevation(record, sampler, anomalies)
                except PMTilesError as exc:
                    # A broken archive is a data condition here; the terrain step fails it itself.
                    unreadable = True
                    record.ascent_m = record.descent_m = None
                    anomalies.append(Anomaly("terrain_unreadable", terrain.name, str(exc)))
        sqlite_path, overlay_path = self.outputs(ctx)
        primaries = [(i + 1, r) for i, r in enumerate(records) if r.secondary_of is None]

        def fill(conn: sqlite3.Connection) -> None:
            placeholders = ",".join("?" * TRAILS_COLUMNS)
            for index, record in enumerate(records):
                trail_id = index + 1
                winner = record.secondary_of + 1 if record.secondary_of is not None else None
                row = trail_row(record, trail_id, winner)
                conn.execute(f"INSERT INTO trails VALUES ({placeholders})", row)
                if record.bbox:
                    lon_min, lat_min, lon_max, lat_max = record.bbox
                    conn.execute(
                        "INSERT INTO trails_rtree VALUES (?, ?, ?, ?, ?)",
                        (trail_id, lon_min, lon_max, lat_min, lat_max),
                    )

        write_sqlite(sqlite_path, "trails", meta, fill)
        features = (trail_feature(r, i) for i, r in primaries if r.legs)
        argv = build_overlay(features, overlay_path, "trails", TRAILS_MIN_ZOOM, TRAILS_MAX_ZOOM)
        return StepOutcome(argv, anomalies)
