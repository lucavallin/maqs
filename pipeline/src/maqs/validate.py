"""Checks every output before it can be reported or released."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

from maqs.pmtiles_header import PMTilesError, read_header, read_metadata

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


@dataclass(frozen=True)
class OutputInfo:
    file: str
    bytes: int
    sha256: str
    tile_type: str
    min_zoom: int
    max_zoom: int
    tiles: int
    compression: str
    attribution: str | None
    source_data_date: str | None
    metadata: dict


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_output(path: Path, expect: Expectation) -> OutputInfo:
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
        metadata=metadata,
    )
