"""The three SQLite layer schemas and the one way they are written: temp file, schema, rows,
metadata, FTS rebuild, VACUUM, rename. Formats are documented in docs/data-format.md."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
SCHEMA_VERSION: dict[str, int] = {"trails": 1, "places": 1, "curvature": 1}

_METADATA = """
CREATE TABLE metadata (
  schema_version INTEGER NOT NULL, layer TEXT NOT NULL, region TEXT NOT NULL,
  data_date TEXT NOT NULL, osm_timestamp TEXT, attribution TEXT NOT NULL
);
"""

SCHEMAS: dict[str, str] = {
    "trails": _METADATA
    + """
CREATE TABLE trails (
  id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL,
  source_licence TEXT, source_date TEXT,
  osm_type TEXT, osm_id INTEGER, ref TEXT, ref_rei TEXT, name TEXT,
  difficulty INTEGER, difficulty_scheme TEXT, difficulty_value TEXT,
  network TEXT, operator TEXT, osmc_symbol TEXT, from_name TEXT, to_name TEXT, roundtrip INTEGER,
  survey_date TEXT, website TEXT,
  length_m REAL NOT NULL, ascent_m REAL, descent_m REAL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  -- geometry: one encoded polyline per leg, legs joined by ';' (outside the polyline alphabet)
  geometry TEXT NOT NULL, geometry_status TEXT NOT NULL,
  secondary_of INTEGER REFERENCES trails(id)
);
CREATE VIRTUAL TABLE trails_fts USING fts5(ref, name, from_name, to_name, operator,
  content='trails', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE trails_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
    "places": _METADATA
    + """
CREATE TABLE places (
  id INTEGER PRIMARY KEY, osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, kind TEXT NOT NULL,
  name TEXT, name_it TEXT, name_de TEXT, name_fur TEXT, name_sl TEXT,
  ele REAL, wikidata TEXT, lon REAL NOT NULL, lat REAL NOT NULL, rank_score REAL NOT NULL
);
CREATE VIRTUAL TABLE places_fts USING fts5(name, name_it, name_de, name_fur, name_sl,
  content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE places_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
    "curvature": _METADATA
    + """
CREATE TABLE segments (
  id INTEGER PRIMARY KEY, osm_way_id INTEGER NOT NULL, name TEXT, ref TEXT,
  highway TEXT NOT NULL, surface TEXT,
  oneway INTEGER NOT NULL DEFAULT 0, maxspeed TEXT, length_m REAL NOT NULL, score REAL NOT NULL,
  start_node INTEGER NOT NULL, end_node INTEGER NOT NULL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry TEXT NOT NULL,
  junction TEXT
);
CREATE TABLE corners (
  id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id),
  ordinal INTEGER NOT NULL,
  apex_lon REAL NOT NULL, apex_lat REAL NOT NULL, min_radius_m REAL NOT NULL,
  direction TEXT NOT NULL,
  entry_m REAL NOT NULL, apex_m REAL NOT NULL, exit_m REAL NOT NULL
);
CREATE INDEX corners_segment ON corners(segment_id, ordinal);
CREATE TABLE junctions (
  segment_id INTEGER NOT NULL REFERENCES segments(id),
  node INTEGER NOT NULL,
  along_m REAL NOT NULL
);
CREATE INDEX junctions_node ON junctions(node);
CREATE INDEX junctions_segment ON junctions(segment_id, along_m);
CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE VIRTUAL TABLE corners_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
}

TABLES: dict[str, frozenset[str]] = {
    "trails": frozenset({"metadata", "trails", "trails_fts", "trails_rtree"}),
    "places": frozenset({"metadata", "places", "places_fts", "places_rtree"}),
    "curvature": frozenset(
        {"metadata", "segments", "corners", "junctions", "segments_rtree", "corners_rtree"}
    ),
}
COUNT_TABLES: dict[str, tuple[str, ...]] = {
    "trails": ("trails",),
    "places": ("places",),
    "curvature": ("segments", "corners", "junctions"),
}
FTS_TABLES: dict[str, tuple[str, ...]] = {
    "trails": ("trails_fts",),
    "places": ("places_fts",),
    "curvature": (),
}


@dataclass(frozen=True)
class Metadata:
    layer: str
    region: str
    data_date: str
    osm_timestamp: str | None


def write_sqlite(
    path: Path, layer: str, meta: Metadata, fill: Callable[[sqlite3.Connection], None]
) -> None:
    """Build the layer database in a temp file and rename it into place, so a crash never
    leaves a half-written file under the final name."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.unlink(missing_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(tmp)
    try:
        conn.executescript(SCHEMAS[layer])
        fill(conn)
        conn.execute(
            "INSERT INTO metadata VALUES (?, ?, ?, ?, ?, ?)",
            (
                SCHEMA_VERSION[layer],
                meta.layer,
                meta.region,
                meta.data_date,
                meta.osm_timestamp,
                ATTRIBUTION,
            ),
        )
        for fts in FTS_TABLES[layer]:
            conn.execute(f"INSERT INTO {fts}({fts}) VALUES ('rebuild')")
        conn.commit()
        conn.execute("VACUUM")
    finally:
        conn.close()
    tmp.replace(path)


def open_readonly(path: Path) -> sqlite3.Connection:
    # as_uri() percent-encodes the path; a raw "file:{path}" would let `?`, `#` and `%` in a
    # directory name redirect the open (and create a stray file).
    return sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)


def table_names(conn: sqlite3.Connection) -> set[str]:
    return {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
