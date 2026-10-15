"""Adapter 1: OSM route=hiking relations, assembled from member ways by our own code.

osmium export cannot assemble route relations, so the ordering is done here: ways are chained
by shared end nodes, reversed when needed, and every irregularity becomes an anomaly in the
build report. Nothing is dropped (brief item 4, ADR 0006).
"""

from __future__ import annotations

import re
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import osmium

from maqs.geometry import Coord, haversine_m
from maqs.steps.base import Anomaly
from maqs.trails.model import TrailRecord

OSM_LICENCE = "ODbL 1.0"

CAI_SCALE: dict[str, int] = {
    "T": 1,
    "E": 2,
    "EE": 3,
    "EEA": 4,
    "EEA:F": 4,
    "EEA:PD": 5,
    "EEA:D": 6,
    "EEA:MD": 6,
    "EEA:ED": 6,
    "EAI": 3,
}
SAC_SCALE: dict[str, int] = {
    "hiking": 1,
    "mountain_hiking": 2,
    "demanding_mountain_hiking": 3,
    "alpine_hiking": 4,
    "demanding_alpine_hiking": 5,
    "difficult_alpine_hiking": 6,
}
FLAGGED_ROLES = frozenset({"alternative", "excursion", "connection"})
_AVS_RE = re.compile(r"alpenverein\s*s(ü|ue|u)dtirol|^avs$", re.IGNORECASE)


def normalise_difficulty(
    cai: str | None, sac: str | None, way_sacs: Sequence[str]
) -> tuple[int | None, str | None, str | None, str | None]:
    """Return (difficulty, scheme, original value, anomaly message or None).

    The relation's own cai_scale wins, then its sac_scale, then the hardest sac_scale on its ways.
    """
    if cai:
        value = cai.strip()
        level = CAI_SCALE.get(value.upper())
        return level, "cai_scale", value, None if level else f"unknown cai_scale {value!r}"
    if sac:
        value = sac.strip()
        level = SAC_SCALE.get(value)
        return level, "sac_scale", value, None if level else f"unknown sac_scale {value!r}"
    known = [(SAC_SCALE[s], s) for s in way_sacs if s in SAC_SCALE]
    if known:
        level, value = max(known)
        return level, "sac_scale:ways", value, None
    return None, None, None, None


def normalise_operator(value: str | None) -> str | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    return "Alpenverein Südtirol" if _AVS_RE.search(text) else text


@dataclass
class WayGeom:
    id: int
    nodes: list[int]
    coords: list[Coord]
    tags: dict[str, str]


Step = tuple[int, bool]  # a way id, and whether the leg walks it in its stored direction


def _turned(steps: list[Step]) -> list[Step]:
    """The same leg walked the other way."""
    return [(wid, not forward) for wid, forward in reversed(steps)]


def _orient(steps: list[Step], closed: bool, position: dict[int, int]) -> list[Step]:
    """Turn a leg to follow member order (`position`: way id -> its first member index).

    An open leg starts with whichever of its two end ways comes first in member order. A closed
    leg has no ends: it is rotated to start with its earliest member and walked towards the
    earlier of that member's two neighbours. A two-way loop has the same neighbour on both
    sides, and a one-way leg has none, so those keep the direction they were built in.
    """
    if not closed:
        return _turned(steps) if position[steps[0][0]] > position[steps[-1][0]] else steps
    first = min(range(len(steps)), key=lambda i: position[steps[i][0]])
    steps = steps[first:] + steps[:first]
    if len(steps) > 2 and position[steps[1][0]] > position[steps[-1][0]]:
        steps = _turned(steps)
        steps = steps[-1:] + steps[:-1]
    return steps


def _leg_coords(steps: list[Step], ways: dict[int, WayGeom]) -> list[Coord]:
    coords: list[Coord] = []
    for wid, forward in steps:
        walked = ways[wid].coords if forward else ways[wid].coords[::-1]
        coords.extend(walked[1:] if coords else walked)  # consecutive ways share their end node
    return coords


def assemble(
    members: Sequence[tuple[int, str]], ways: dict[int, WayGeom]
) -> tuple[list[list[Coord]], str, list[Anomaly]]:
    """Chain member ways into continuous legs; irregularities become anomalies, never errors.

    Ways are chained by shared end nodes first; each finished leg is then turned to follow
    member order, and a way walked against its stored direction is flagged `reversed`.
    """
    anomalies: list[Anomaly] = []
    position: dict[int, int] = {}
    missing = False
    for index, (wid, role) in enumerate(members):
        if wid not in ways or len(ways[wid].nodes) < 2:
            anomalies.append(
                Anomaly("missing_member", f"way/{wid}", "member way not in the extract")
            )
            missing = True
            continue
        if role in FLAGGED_ROLES:
            message = f"member role {role!r} kept in the main geometry"
            anomalies.append(Anomaly("role", f"way/{wid}", message))
        position.setdefault(wid, index)
    unused = list(position)  # usable way ids in member order, each once
    legs: list[list[Coord]] = []
    leg_ways: list[list[int]] = []  # way ids per leg, in leg order, for the gap anomalies
    reversed_message = "member way runs against the route direction"
    while unused:
        first_id = unused.pop(0)
        chain: deque[Step] = deque([(first_id, True)])
        start, end = ways[first_id].nodes[0], ways[first_id].nodes[-1]
        extended = True
        while extended:
            extended = False
            for wid in list(unused):
                head, tail = ways[wid].nodes[0], ways[wid].nodes[-1]
                if head == end:
                    chain.append((wid, True))
                    end = tail
                elif tail == end:
                    chain.append((wid, False))
                    end = head
                elif tail == start:
                    chain.appendleft((wid, True))
                    start = head
                elif head == start:
                    chain.appendleft((wid, False))
                    start = tail
                else:
                    continue
                unused.remove(wid)
                extended = True
        steps = _orient(list(chain), start == end, position)
        anomalies.extend(
            Anomaly("reversed", f"way/{wid}", reversed_message)
            for wid, forward in steps
            if not forward
        )
        legs.append(_leg_coords(steps, ways))
        leg_ways.append([wid for wid, _ in steps])
    for i in range(1, len(legs)):
        gap = haversine_m(legs[i - 1][-1], legs[i][0])
        message = f"gap of {gap:.0f} m before this way"
        anomalies.append(Anomaly("gap", f"way/{leg_ways[i][0]}", message))
    status = "incomplete" if missing or not legs else ("gaps" if len(legs) > 1 else "ordered")
    return legs, status, anomalies


def _collapse_reversed(
    anomalies: list[Anomaly], rid: int, members: Sequence[tuple[int, str]], ways: dict[int, WayGeom]
) -> list[Anomaly]:
    """Replace the per-way `reversed` anomalies with one entry for the relation.

    A long route can reverse hundreds of ways; one line per relation keeps the build report's
    capped anomaly list useful for the other kinds. A relation with no reversals gets no entry.
    """
    flipped = sum(1 for a in anomalies if a.kind == "reversed")
    if not flipped:
        return anomalies
    used = len({wid for wid, _ in members if wid in ways and len(ways[wid].nodes) >= 2})
    kept = [a for a in anomalies if a.kind != "reversed"]
    kept.append(Anomaly("reversed", f"relation/{rid}", f"{flipped} of {used} member ways reversed"))
    return kept


def _yes_no(value: str | None) -> int | None:
    if value is None:
        return None
    return {"yes": 1, "true": 1, "1": 1, "no": 0, "false": 0, "0": 0}.get(value.strip().lower())


def read_osm_trails(hiking_pbf: Path, *, source_date: str | None) -> list[TrailRecord]:
    """One TrailRecord per route=hiking relation in the PBF, ordered by relation id."""
    relations: dict[int, tuple[dict[str, str], list[tuple[int, str]], int]] = {}
    hiking = osmium.filter.TagFilter(("route", "hiking"))
    for rel in osmium.FileProcessor(str(hiking_pbf), osmium.osm.RELATION).with_filter(hiking):
        members = [(m.ref, m.role) for m in rel.members if m.type in ("w", "way")]
        relation_members = sum(1 for m in rel.members if m.type in ("r", "relation"))
        relations[rel.id] = (dict(rel.tags), members, relation_members)
    way_ids = {wid for _, members, _ in relations.values() for wid, _ in members}
    ways: dict[int, WayGeom] = {}
    if way_ids:
        way_filter = osmium.filter.IdFilter(way_ids).enable_for(osmium.osm.WAY)
        processor = osmium.FileProcessor(str(hiking_pbf)).with_locations().with_filter(way_filter)
        for obj in processor:
            if obj.is_way():
                located = [n for n in obj.nodes if n.location.valid()]
                ways[obj.id] = WayGeom(
                    obj.id,
                    [n.ref for n in located],
                    [(n.lon, n.lat) for n in located],
                    dict(obj.tags),
                )
    records: list[TrailRecord] = []
    for rid in sorted(relations):
        tags, members, relation_members = relations[rid]
        legs, status, anomalies = assemble(members, ways)
        anomalies = _collapse_reversed(anomalies, rid, members, ways)
        if relation_members:
            message = f"relation members ignored (superroute): {relation_members}"
            anomalies.append(Anomaly("relation_member", f"relation/{rid}", message))
        if not legs:
            message = "relation has no way members in the extract"
            anomalies.append(Anomaly("no_geometry", f"relation/{rid}", message))
        way_sacs = [
            ways[wid].tags["sac_scale"]
            for wid, _ in members
            if wid in ways and "sac_scale" in ways[wid].tags
        ]
        difficulty, scheme, value, problem = normalise_difficulty(
            tags.get("cai_scale"), tags.get("sac_scale"), way_sacs
        )
        if problem:
            anomalies.append(Anomaly("difficulty", f"relation/{rid}", problem))
        records.append(
            TrailRecord(
                source="osm",
                source_id=f"relation/{rid}",
                source_licence=OSM_LICENCE,
                source_date=source_date,
                osm_type="relation",
                osm_id=rid,
                ref=tags.get("ref"),
                ref_rei=tags.get("ref:REI"),
                name=tags.get("name"),
                difficulty=difficulty,
                difficulty_scheme=scheme,
                difficulty_value=value,
                network=tags.get("network"),
                operator=normalise_operator(tags.get("operator")),
                osmc_symbol=tags.get("osmc:symbol"),
                from_name=tags.get("from"),
                to_name=tags.get("to"),
                roundtrip=_yes_no(tags.get("roundtrip")),
                survey_date=tags.get("survey:date"),
                website=tags.get("website"),
                legs=legs,
                geometry_status=status,
                anomalies=anomalies,
            )
        )
    return records
