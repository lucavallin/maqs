# pipeline/src/maqs/manifest.py
"""Assemble manifest.json from the per-region build reports (docs/data-format.md)."""

from __future__ import annotations

import copy
import json
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

from maqs.config import BasePack, Config, Region
from maqs.layers import STANDARD_LAYERS
from maqs.report import report_path
from maqs.schemas import SchemaError, validate

MANIFEST_VERSION = 1
SHORTBREAD_VERSION = "1.0"
REPO = "lucavallin/maqs"
CI_RELEASE = "data-ci"
VERSIONED_KEYS = frozenset({"layer", "layer_schema_version", "data_date"})
OVERLAY_LAYERS = frozenset({"trails", "places"})

# Display strings verbatim from DATA_LICENSE.md (a test keeps them in sync).
ATTRIBUTION: tuple[dict, ...] = (
    {
        "text": "© OpenStreetMap contributors",
        "licence": "ODbL 1.0",
        "url": "https://www.openstreetmap.org/copyright",
        "layers": ["basemap", "trails", "places", "curvature"],
    },
    {
        "text": "CC BY 4.0 ESA WorldCover 2021",
        "licence": "CC BY 4.0",
        "url": "https://esa-worldcover.org/en/data-access",
        "layers": ["basemap"],
    },
    {
        "text": "© Mapterhorn",
        "licence": "multiple open licences, listed at url",
        "url": "https://mapterhorn.com/attribution",
        "layers": ["terrain", "terrain-hd"],
    },
)


class ManifestError(ValueError):
    """The dist directory does not hold a complete, successful build."""


def asset_url(release: str, file: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{release}/{file}"


def read_report(dist: Path, label: str) -> dict:
    path = report_path(dist / label)
    if not path.exists():
        raise ManifestError(f"{label}: build-report.json not found")
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ManifestError(f"{label}: build-report.json: {exc}") from exc
    if not report.get("validation", {}).get("ok", False):
        failures = "; ".join(report.get("validation", {}).get("failures", [])) or "unknown"
        raise ManifestError(f"{label}: build failed: {failures}")
    for step in report.get("steps", []):
        for output in step.get("outputs", []):
            if not output.keys() >= VERSIONED_KEYS:
                raise ManifestError(
                    f"{label}: build-report.json predates the versioned outputs; "
                    "rebuild with --force"
                )
    return report


def entry_from_output(output: dict, release: str) -> dict:
    entry = {
        "layer_schema_version": output["layer_schema_version"],
        "file": output["file"],
        "url": asset_url(release, output["file"]),
        "bytes": output["bytes"],
        "sha256": output["sha256"],
        "data_date": output["data_date"],
        "osm_timestamp": output.get("source_data_date"),
    }
    if output["layer"] in OVERLAY_LAYERS and output["file"].endswith(".pmtiles"):
        entry["role"] = "overlay"
    return entry


def _sort_entries(entries: list[dict]) -> list[dict]:
    return sorted(entries, key=lambda e: (-e["layer_schema_version"], "role" in e))


def region_layers(report: dict, release: str, *, required: Sequence[str]) -> dict[str, list[dict]]:
    label = report["region"]
    layers: dict[str, list[dict]] = {}
    for step in report["steps"]:
        if step["status"] == "failed":
            continue
        for output in step["outputs"]:
            layers.setdefault(output["layer"], []).append(entry_from_output(output, release))
    for name in required:
        if not layers.get(name):
            raise ManifestError(f"{label}: layer {name} missing")
    return {name: _sort_entries(entries) for name, entries in layers.items()}


def _region_doc(region: Region, dist: Path, release: str) -> dict:
    report = read_report(dist, region.id)
    return {
        "id": region.id,
        "name": {"it": region.name["it"], "en": region.name["en"]},
        "bbox": list(region.bbox),
        "layers": region_layers(report, release, required=STANDARD_LAYERS),
    }


def _base_docs(config: Config, dist: Path, release: str) -> list[dict]:
    if not config.base_packs:
        return []
    if not report_path(dist / "base").exists():
        needed = ", ".join(f"base-{pack.id}" for pack in config.base_packs)
        raise ManifestError(f"base: build-report.json not found (needed for {needed})")
    report = read_report(dist, "base")
    by_step = {step["name"]: step for step in report["steps"]}
    docs = []
    for pack in config.base_packs:
        step = by_step.get(f"base-{pack.id}")
        if step is None or step["status"] == "failed" or not step["outputs"]:
            raise ManifestError(f"base-{pack.id}: not built")
        for output in step["outputs"]:
            if output["layer"] != "basemap":
                raise ManifestError(f"base-{pack.id}: unexpected layer {output['layer']}")
        entries = _sort_entries([entry_from_output(o, release) for o in step["outputs"]])
        docs.append(_base_doc(pack, entries))
    return docs


def _base_doc(pack: BasePack, entries: list[dict]) -> dict:
    return {
        "id": pack.id,
        "regions": list(pack.regions),
        "max_zoom": pack.max_zoom,
        "layers": {"basemap": entries},
    }


def url_tag(url: str) -> str:
    """The release tag an asset URL names: the path segment after `/releases/download/`."""
    return url.partition("/releases/download/")[2].partition("/")[0]


def carry_over(current: dict, previous: dict) -> dict:
    """Append the previous release's lower-version entries so old clients keep a file to read.

    An entry is carried only when its URL names `previous["release"]`, that is, when it was
    built for the previous release. An entry the previous manifest had itself carried names an
    older tag and is dropped, so the window ends after one release. A same-month re-run
    (`previous["release"] == current["release"]`) keeps every lower entry. Carried entries are
    copied unchanged; rewriting a URL's tag would keep the window open forever.
    """
    rerun = previous["release"] == current["release"]
    merged = copy.deepcopy(current)
    prev_regions = {r["id"]: r for r in previous.get("regions", [])}
    prev_base = {b["id"]: b for b in previous.get("base", [])}
    for doc, prev in [(r, prev_regions.get(r["id"])) for r in merged["regions"]] + [
        (b, prev_base.get(b["id"])) for b in merged["base"]
    ]:
        if prev is None:
            continue
        for layer, entries in doc["layers"].items():
            floor = min(e["layer_schema_version"] for e in entries)
            older = [
                e
                for e in prev["layers"].get(layer, [])
                if e["layer_schema_version"] < floor
                and (rerun or url_tag(e["url"]) == previous["release"])
            ]
            doc["layers"][layer] = _sort_entries(entries + copy.deepcopy(older))
    return merged


def _check_previous(previous: dict, release: str) -> None:
    """The previous manifest passes the schema and, for a dated release, is not a later one."""
    try:
        validate(previous, "manifest")
    except SchemaError as exc:
        raise ManifestError(f"previous manifest: {exc.path}: {exc.message}") from exc
    earlier = previous["release"]
    if release != CI_RELEASE and (earlier == CI_RELEASE or earlier > release):
        raise ManifestError(
            f"previous manifest {earlier} is not a dated release at or before {release}"
        )


def _check_entry_urls(manifest: dict) -> None:
    """What the schema cannot tie together, on every entry, carried ones included."""
    dated = manifest["release"] != CI_RELEASE
    docs = [(r["id"], r) for r in manifest["regions"]]
    docs += [(f"base-{b['id']}", b) for b in manifest["base"]]
    for label, doc in docs:
        for layer, entries in doc["layers"].items():
            for e in entries:
                if e["url"].rsplit("/", 1)[1] != e["file"]:
                    raise ManifestError(
                        f"{label}: {layer}: url {e['url']} does not name {e['file']}"
                    )
                if dated and url_tag(e["url"]) == CI_RELEASE:
                    raise ManifestError(f"{label}: {layer}: {e['file']} points at {CI_RELEASE}")


def build_manifest(
    config: Config,
    dist: Path,
    release: str,
    *,
    regions: Sequence[str] | None = None,
    previous: dict | None = None,
    now: datetime | None = None,
) -> dict:
    moment = now or datetime.now(UTC)
    if moment.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    stamp = moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    if previous is not None:
        _check_previous(previous, release)
    if regions is None:
        ids = config.region_ids(include_fixtures=False)
    else:
        known = config.region_ids(include_fixtures=True)
        for rid in regions:
            if rid not in known:
                raise ManifestError(f"unknown region '{rid}'")
        ids = [rid for rid in known if rid in regions]
    region_docs = [_region_doc(config.region(rid), dist, release) for rid in ids]
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "created_at": stamp,
        "release": release,
        "shortbread_version": SHORTBREAD_VERSION,
        "attribution": copy.deepcopy(list(ATTRIBUTION)),
        "regions": region_docs,
        "base": _base_docs(config, dist, release),
    }
    if previous is not None:
        manifest = carry_over(manifest, previous)
    validate(manifest, "manifest")
    _check_entry_urls(manifest)
    return manifest


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    text = json.dumps(manifest, indent=2, ensure_ascii=False, allow_nan=False)
    tmp.write_text(text + "\n", encoding="utf-8")
    tmp.replace(path)
