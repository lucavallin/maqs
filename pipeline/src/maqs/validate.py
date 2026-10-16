"""Checks every output before it can be reported or released."""

from __future__ import annotations

import hashlib
import logging
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

from maqs.config import RowRange
from maqs.pmtiles_header import PMTilesError, read_header, read_metadata
from maqs.sqlite_out import SCHEMA_VERSION, open_readonly, table_names

log = logging.getLogger("maqs.validate")

SIZE_CAP = int(1.9 * 2**30)
BASE_PACK_CAP = 15_000_000
TEST_REGION_WARN = 5_000_000
ALLOWED_COMPRESSION = {"none", "gzip"}


class ValidationError(Exception):
    """One or more checks failed; the message lists all of them."""


@dataclass(frozen=True)
class Expectation:
    min_zoom: int
    max_zoom: int
    tile_types: frozenset[str]
    size_cap: int = SIZE_CAP
    # The archive the output was cut from, copied into the report as provenance.
    source: str | None = None


@dataclass(frozen=True)
class SqliteExpectation:
    layer: str
    region: str
    tables: frozenset[str]
    count_tables: tuple[str, ...]
    row_ranges: dict[str, RowRange] = field(default_factory=dict)
    size_cap: int = SIZE_CAP


@dataclass(frozen=True)
class OutputInfo:
    file: str
    bytes: int
    sha256: str
    tile_type: str | None
    min_zoom: int | None
    max_zoom: int | None
    tiles: int | None
    compression: str | None
    attribution: str | None
    source_data_date: str | None
    source: str | None
    metadata: dict
    rows: dict[str, int] | None = None
    layer: str | None = None
    layer_schema_version: int | None = None
    data_date: str | None = None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_pmtiles(path: Path, expect: Expectation) -> OutputInfo:
    failures: list[str] = []
    size = path.stat().st_size
    if size >= expect.size_cap:
        failures.append(f"{size} bytes exceeds the size cap of {expect.size_cap}")
    try:
        header = read_header(path)
    except PMTilesError as exc:
        extra = "; " + "; ".join(failures) if failures else ""
        raise ValidationError(f"{path.name}: {exc}{extra}") from exc
    if header.tile_compression not in ALLOWED_COMPRESSION:
        failures.append(
            f"tile compression {header.tile_compression} (MapLibre reads gzip or none only)"
        )
    metadata: dict = {}
    if header.internal_compression not in ALLOWED_COMPRESSION:
        failures.append(f"internal compression {header.internal_compression}")
    else:
        try:
            metadata = read_metadata(path, header)
        except PMTilesError as exc:
            failures.append(str(exc))
    if (header.min_zoom, header.max_zoom) != (expect.min_zoom, expect.max_zoom):
        failures.append(
            f"zoom range {header.min_zoom}-{header.max_zoom}, "
            f"expected {expect.min_zoom}-{expect.max_zoom}"
        )
    if header.tile_type not in expect.tile_types:
        failures.append(
            f"tile type {header.tile_type}, expected one of {sorted(expect.tile_types)}"
        )
    if header.addressed_tiles == 0:
        failures.append("zero tiles")
    if not header.clustered:
        failures.append("not clustered")
    if failures:
        raise ValidationError(f"{path.name}: " + "; ".join(failures))
    return OutputInfo(
        file=path.name,
        bytes=size,
        sha256=sha256(path),
        tile_type=header.tile_type,
        min_zoom=header.min_zoom,
        max_zoom=header.max_zoom,
        tiles=header.addressed_tiles,
        compression=header.tile_compression,
        attribution=metadata.get("attribution"),
        source_data_date=metadata.get("planetiler:osm:osmosisreplicationtime"),
        source=expect.source,
        metadata=metadata,
    )


def validate_sqlite(path: Path, expect: SqliteExpectation) -> OutputInfo:
    failures: list[str] = []
    size = path.stat().st_size
    if size >= expect.size_cap:
        failures.append(f"{size} bytes exceeds the size cap of {expect.size_cap}")
    try:
        conn = open_readonly(path)
    except sqlite3.Error as exc:
        raise ValidationError(f"{path.name}: cannot open: {exc}") from exc
    try:
        try:
            check = conn.execute("PRAGMA integrity_check").fetchone()
        except sqlite3.DatabaseError as exc:
            raise ValidationError(f"{path.name}: {exc}") from exc
        if check != ("ok",):
            raise ValidationError(f"{path.name}: integrity check failed: {check}")
        missing = sorted(expect.tables - table_names(conn))
        if missing:
            raise ValidationError(f"{path.name}: missing tables: {', '.join(missing)}")
        meta = conn.execute(
            "SELECT schema_version, layer, region, osm_timestamp, attribution FROM metadata"
        ).fetchall()
        if len(meta) != 1:
            failures.append(f"metadata has {len(meta)} rows, expected 1")
            osm_timestamp, attribution = None, None
        else:
            schema_version, layer, region, osm_timestamp, attribution = meta[0]
            if layer != expect.layer:
                failures.append(f"metadata layer {layer!r}, expected {expect.layer!r}")
            if region != expect.region:
                failures.append(f"metadata region {region!r}, expected {expect.region!r}")
            expected_version = SCHEMA_VERSION.get(expect.layer)
            if not isinstance(schema_version, int):
                failures.append(f"metadata schema_version {schema_version!r} is not an integer")
            elif schema_version != expected_version:
                failures.append(
                    f"metadata schema_version {schema_version}, expected {expected_version}"
                )
        rows: dict[str, int] = {}
        for table in expect.count_tables:
            rows[table] = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            wanted = expect.row_ranges.get(table)
            if wanted is not None and not (wanted.min <= rows[table] <= wanted.max):
                failures.append(
                    f"{table} has {rows[table]} rows, expected {wanted.min}..{wanted.max}"
                )
            elif rows[table] == 0:
                log.warning("%s: %s has zero rows", path.name, table)
    except sqlite3.DatabaseError as exc:
        raise ValidationError(f"{path.name}: {exc}") from exc
    finally:
        conn.close()
    if failures:
        raise ValidationError(f"{path.name}: " + "; ".join(failures))
    return OutputInfo(
        file=path.name,
        bytes=size,
        sha256=sha256(path),
        tile_type=None,
        min_zoom=None,
        max_zoom=None,
        tiles=None,
        compression=None,
        attribution=attribution,
        source_data_date=osm_timestamp,
        source=None,
        metadata={},
        rows=rows,
    )


def validate_output(path: Path, expect: Expectation | SqliteExpectation) -> OutputInfo:
    if isinstance(expect, SqliteExpectation):
        return validate_sqlite(path, expect)
    return validate_pmtiles(path, expect)
