"""Tiny OSM PBF files for tests, written with pyosmium. Objects are written in the order
osmium expects: nodes, ways, relations, each by ascending id."""

from __future__ import annotations

from pathlib import Path

import osmium
import osmium.osm.mutable as mutable

Coord = tuple[float, float]


def write_osm(
    path: Path,
    nodes: dict[int, Coord],
    ways: dict[int, tuple[list[int], dict[str, str]]],
    relations: dict[int, tuple[list[tuple[str, int, str]], dict[str, str]]],
) -> Path:
    with osmium.SimpleWriter(str(path), overwrite=True) as writer:
        for nid in sorted(nodes):
            writer.add_node(mutable.Node(id=nid, location=nodes[nid]))
        for wid in sorted(ways):
            node_ids, tags = ways[wid]
            writer.add_way(mutable.Way(id=wid, nodes=node_ids, tags=tags))
        for rid in sorted(relations):
            members, tags = relations[rid]
            writer.add_relation(mutable.Relation(id=rid, members=members, tags=tags))
    return path
