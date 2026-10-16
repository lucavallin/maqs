"""Pre-publish checks for a data release and its release notes (docs/architecture.md)."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from maqs.manifest import RELEASE_TAG, url_tag
from maqs.validate import sha256

MANIFEST_ASSET = "manifest.json"
RELEASE_FIELDS = ("tag_name", "draft", "prerelease", "created_at", "assets")


class ReleaseError(ValueError):
    """A file the manifest names for this release is missing or differs from the manifest."""


class ReleaseStateError(ValueError):
    """The published releases are in a state the workflow must not build on without the owner."""


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


def _check_releases(releases: object) -> list[dict]:
    """The shape `gh api repos/<owner>/<repo>/releases` returns, for the fields read here."""
    if not isinstance(releases, list):
        raise ReleaseStateError("releases: expected a JSON array of releases")
    for i, r in enumerate(releases):
        if not isinstance(r, dict) or any(key not in r for key in RELEASE_FIELDS):
            raise ReleaseStateError(f"releases[{i}]: needs {', '.join(RELEASE_FIELDS)}")
        assets = r["assets"]
        if not isinstance(assets, list) or not all(
            isinstance(a, dict) and "name" in a for a in assets
        ):
            raise ReleaseStateError(f"releases[{i}]: every asset needs a name")
    return releases


def _has_manifest(release: dict) -> bool:
    return any(a["name"] == MANIFEST_ASSET for a in release["assets"])


def choose_previous(releases: object, release: str) -> tuple[str | None, list[str]]:
    """The data release whose manifest.json this run carries over from, and warnings.

    `releases` is the list the REST API returns. Candidates are the published (non-draft,
    non-prerelease) `data-YYYY-MM` releases, newest tag first; the previous release is the
    newest candidate with a `manifest.json` asset. A candidate newer than that one has no
    manifest because a run failed before its last upload. When it is this run's own tag, this
    run repairs it (a warning). When it is the newest candidate and another month, the
    workflow stops (`ReleaseStateError`): carrying over from an older manifest would silently
    end ADR 0012's window, so the owner re-runs that month or deletes the release. An older
    one is an orphan clients never read (a warning).

    The API payload does not say which release is marked latest. GitHub picks the newest
    published release by `created_at` unless one is marked explicitly, so a release that is
    newest by `created_at` and is not a data release gets a warning: clients would read
    `releases/latest/download/manifest.json` from it and find nothing.
    """
    published = [r for r in _check_releases(releases) if not r["draft"] and not r["prerelease"]]
    warnings: list[str] = []
    if published:
        newest_created = max(r["created_at"] for r in published)
        for r in published:
            if r["created_at"] == newest_created and not RELEASE_TAG.fullmatch(r["tag_name"]):
                warnings.append(
                    f"{r['tag_name']} is the newest release by created_at;"
                    " clients would see a non-data release as latest"
                )
    candidates = sorted(
        (r for r in published if RELEASE_TAG.fullmatch(r["tag_name"])),
        key=lambda r: r["tag_name"],
        reverse=True,
    )
    previous = next((r["tag_name"] for r in candidates if _has_manifest(r)), None)
    for position, r in enumerate(candidates):
        tag = r["tag_name"]
        if tag == previous:
            break
        if tag == release:
            warnings.append(f"{tag} has no manifest.json; this run repairs it")
        elif position == 0:
            raise ReleaseStateError(
                f"latest data release {tag} has no manifest.json; re-run that month or have"
                f" the owner remove it with `gh release delete {tag} --cleanup-tag`"
            )
        else:
            warnings.append(f"{tag} has no manifest.json; skipped, an orphan clients never saw")
    return previous, warnings
