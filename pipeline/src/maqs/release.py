"""Pre-publish checks for a data release and its release notes (docs/architecture.md)."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from maqs.manifest import url_tag
from maqs.validate import sha256


class ReleaseError(ValueError):
    """A file the manifest names for this release is missing or differs from the manifest."""


@dataclass(frozen=True)
class Asset:
    file: str
    path: Path
    bytes: int


def _entries(manifest: dict) -> Iterator[tuple[str, dict]]:
    for region in manifest["regions"]:
        for entries in region["layers"].values():
            for entry in entries:
                yield region["id"], entry
    for pack in manifest["base"]:
        for entry in pack["layers"]["basemap"]:
            yield "base", entry


def carried_count(manifest: dict) -> int:
    release = manifest["release"]
    return sum(1 for _, e in _entries(manifest) if url_tag(e["url"]) != release)


def local_assets(manifest: dict, dist: Path) -> list[Asset]:
    """Every file this release must upload, checked against the manifest's bytes and sha256."""
    release = manifest["release"]
    assets: list[Asset] = []
    for label, entry in _entries(manifest):
        if url_tag(entry["url"]) != release:
            continue  # carried from an earlier release; its file lives there
        path = dist / label / entry["file"]
        if not path.exists():
            raise ReleaseError(f"{entry['file']}: missing (expected at {path})")
        size = path.stat().st_size
        if size != entry["bytes"]:
            raise ReleaseError(f"{entry['file']}: {size} bytes, manifest says {entry['bytes']}")
        if sha256(path) != entry["sha256"]:
            raise ReleaseError(f"{entry['file']}: sha256 mismatch")
        assets.append(Asset(entry["file"], path, size))
    return assets


def release_notes(manifest: dict, carried: int) -> str:
    month = manifest["release"].removeprefix("data-")
    lines = [f"# Map data {month}", "", f"Built {manifest['created_at']}.", "", "## Regions", ""]
    for region in manifest["regions"]:
        parts = []
        for layer, entries in region["layers"].items():
            stamp = entries[0]["osm_timestamp"] or "n/a"
            parts.append(f"{layer} {stamp}")
        lines.append(f"- {region['id']}: " + ", ".join(parts))
    if manifest["base"]:
        lines += ["", "## Base packs", ""]
        lines += [
            f"- base pack {p['id']} (z0–{p['max_zoom']}): {', '.join(p['regions'])}"
            for p in manifest["base"]
        ]
    lines += [
        "",
        f"{carried} entries carried from earlier releases.",
        "",
        "Attribution: " + "; ".join(a["text"] for a in manifest["attribution"]) + ".",
        "",
    ]
    return "\n".join(lines)
