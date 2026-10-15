"""The curvature layer: one segment per configured road way, with its corners."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path

import osmium

from maqs.config import Bbox, CurvatureConfig
from maqs.context import BuildContext
from maqs.curvature.score import Corner, score_way
from maqs.geometry import Coord, bbox_of, encode_polyline, line_length_m
from maqs.osm import extract
from maqs.sqlite_out import COUNT_TABLES, TABLES, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.steps.data import metadata_for
from maqs.validate import Expectation, SqliteExpectation


def parse_oneway(value: str | None) -> int:
    """OSM `oneway` as 1 (with the way's direction), -1 (against it) or 0 (both ways)."""
    if value is None:
        return 0
    text = value.strip().lower()
    if text in ("yes", "true", "1"):
        return 1
    if text == "-1":
        return -1
    return 0


@dataclass
class SegmentRecord:
    osm_way_id: int
    name: str | None
    ref: str | None
    highway: str
    surface: str | None
    oneway: int
    maxspeed: str | None
    coords: list[Coord]
    start_node: int
    end_node: int
    score: float
    corners: list[Corner]


def read_roads(pbf: Path, config: CurvatureConfig) -> tuple[list[SegmentRecord], list[Anomaly]]:
    """One segment per way of a configured class and surface, in file order.

    Two-node ways are kept with score 0 and no corners: they carry the adjacency the corner
    lookahead follows across straight connectors. Ways with fewer than two located nodes are
    skipped and reported; a kept way with unlocated nodes is joined over the gap and reported.
    """
    segments: list[SegmentRecord] = []
    anomalies: list[Anomaly] = []
    highways = set(config.highways)
    excluded = set(config.exclude_surfaces)
    for obj in osmium.FileProcessor(str(pbf)).with_locations():
        if not obj.is_way():
            continue
        tags = dict(obj.tags)
        if tags.get("highway") not in highways or tags.get("surface") in excluded:
            continue
        located = [n for n in obj.nodes if n.location.valid()]
        if len(located) < 2:
            message = f"{len(located)} located nodes; need 2"
            anomalies.append(Anomaly("too_short", f"way/{obj.id}", message))
            continue
        if len(located) < len(obj.nodes):
            message = f"{len(obj.nodes) - len(located)} of {len(obj.nodes)} nodes have no location"
            anomalies.append(Anomaly("unlocated_nodes", f"way/{obj.id}", message))
        merged, score, corners = score_way([(n.lon, n.lat) for n in located])
        segments.append(
            SegmentRecord(
                osm_way_id=obj.id,
                name=tags.get("name"),
                ref=tags.get("ref"),
                highway=tags["highway"],
                surface=tags.get("surface"),
                oneway=parse_oneway(tags.get("oneway")),
                maxspeed=tags.get("maxspeed"),
                coords=merged,
                start_node=located[0].ref,
                end_node=located[-1].ref,
                score=score,
                corners=corners,
            )
        )
    return segments, anomalies


def segment_row(s: SegmentRecord, segment_id: int, bbox: Bbox) -> tuple:
    lon_min, lat_min, lon_max, lat_max = bbox
    return (
        segment_id,
        s.osm_way_id,
        s.name,
        s.ref,
        s.highway,
        s.surface,
        s.oneway,
        s.maxspeed,
        line_length_m(s.coords),
        s.score,
        s.start_node,
        s.end_node,
        lon_min,
        lat_min,
        lon_max,
        lat_max,
        encode_polyline(s.coords),
    )


def corner_row(c: Corner, corner_id: int, segment_id: int, ordinal: int) -> tuple:
    lon, lat = c.apex
    return (
        corner_id,
        segment_id,
        ordinal,
        lon,
        lat,
        c.min_radius_m,
        c.direction,
        c.entry_m,
        c.apex_m,
        c.exit_m,
    )


class CurvatureStep:
    name = "curvature"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-curvature.sqlite"]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx.require_region()
        segments_range = region.expect.get("curvature_segments")
        ranges = {} if segments_range is None else {"segments": segments_range}
        return SqliteExpectation(
            "curvature", region.id, TABLES["curvature"], COUNT_TABLES["curvature"], ranges
        )

    def build(self, ctx: BuildContext) -> StepOutcome:
        config = ctx.config.curvature
        expression = "w/highway=" + ",".join(config.highways)
        roads = extract.filtered_region_pbf(ctx, "roads", [expression])
        meta = metadata_for(ctx, "curvature")
        segments, anomalies = read_roads(roads, config)

        def fill(conn: sqlite3.Connection) -> None:
            corner_id = 0
            for index, s in enumerate(segments):
                segment_id = index + 1
                bbox = bbox_of(s.coords)
                row = segment_row(s, segment_id, bbox)
                conn.execute(f"INSERT INTO segments VALUES ({','.join('?' * len(row))})", row)
                lon_min, lat_min, lon_max, lat_max = bbox
                conn.execute(
                    "INSERT INTO segments_rtree VALUES (?, ?, ?, ?, ?)",
                    (segment_id, lon_min, lon_max, lat_min, lat_max),
                )
                for ordinal, c in enumerate(s.corners):
                    corner_id += 1
                    row = corner_row(c, corner_id, segment_id, ordinal)
                    conn.execute(f"INSERT INTO corners VALUES ({','.join('?' * len(row))})", row)
                    lon, lat = c.apex
                    conn.execute(
                        "INSERT INTO corners_rtree VALUES (?, ?, ?, ?, ?)",
                        (corner_id, lon, lon, lat, lat),
                    )

        write_sqlite(self.outputs(ctx)[0], "curvature", meta, fill)
        return StepOutcome([], anomalies)
