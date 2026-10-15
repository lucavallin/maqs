"""The normalised trail record every source adapter emits (ADR 0006)."""

from __future__ import annotations

from dataclasses import dataclass, field

from maqs.geometry import Coord, bbox_of, line_length_m
from maqs.steps.base import Anomaly

GEOMETRY_STATUSES = ("ordered", "gaps", "incomplete")


@dataclass
class TrailRecord:
    source: str
    source_id: str
    source_licence: str | None
    source_date: str | None
    osm_type: str | None
    osm_id: int | None
    ref: str | None
    ref_rei: str | None
    name: str | None
    difficulty: int | None
    difficulty_scheme: str | None
    difficulty_value: str | None
    network: str | None
    operator: str | None
    osmc_symbol: str | None
    from_name: str | None
    to_name: str | None
    roundtrip: int | None
    survey_date: str | None
    website: str | None
    legs: list[list[Coord]]
    geometry_status: str
    anomalies: list[Anomaly] = field(default_factory=list)
    ascent_m: float | None = None
    descent_m: float | None = None
    secondary_of: int | None = None

    @property
    def coords(self) -> list[Coord]:
        return [c for leg in self.legs for c in leg]

    @property
    def length_m(self) -> float:
        return sum(line_length_m(leg) for leg in self.legs)

    @property
    def bbox(self) -> tuple[float, float, float, float] | None:
        coords = self.coords
        return bbox_of(coords) if coords else None
