# pipeline/tests/manifest_fixtures.py
"""Synthetic build reports for manifest tests: no files, no network."""

from __future__ import annotations

import json
from pathlib import Path

from maqs.layers import output_name

SHA = "0123456789abcdef" * 4


def output(
    label: str, layer: str, ext: str, *, nbytes: int = 1000, ts: str | None = "2026-10-31T20:21:00Z"
) -> dict:
    return {
        "file": output_name(label, layer, ext),
        "bytes": nbytes,
        "sha256": SHA,
        "tile_type": "mvt" if ext == "pmtiles" else None,
        "min_zoom": 0 if ext == "pmtiles" else None,
        "max_zoom": 14 if ext == "pmtiles" else None,
        "tiles": 10 if ext == "pmtiles" else None,
        "compression": "gzip" if ext == "pmtiles" else None,
        "attribution": None,
        "source_data_date": ts,
        "source": None,
        "layer": layer,
        "layer_schema_version": 1,
        "data_date": "2026-11-01",
    }


def step(name: str, outputs: list[dict], status: str = "built", error: str | None = None) -> dict:
    d = {
        "name": name,
        "status": status,
        "seconds": 1.0,
        "command": [],
        "outputs": outputs,
        "anomalies": [],
        "anomaly_count": 0,
        "anomaly_kinds": {},
    }
    if error:
        d["error"] = error
    return d


def region_report(label: str, *, drop: str | None = None, fail: str | None = None) -> dict:
    steps = [
        step("basemap", [output(label, "basemap", "pmtiles", ts="2026-06-07T23:59:58Z")]),
        step("terrain", [output(label, "terrain", "pmtiles", ts=None)]),
        step("trails", [output(label, "trails", "sqlite"), output(label, "trails", "pmtiles")]),
        step("places", [output(label, "places", "sqlite"), output(label, "places", "pmtiles")]),
        step("curvature", [output(label, "curvature", "sqlite")]),
    ]
    steps = [s for s in steps if s["name"] != drop]
    failures = []
    if fail:
        for s in steps:
            if s["name"] == fail:
                s["status"], s["error"], s["outputs"] = "failed", "boom", []
                failures.append(f"{fail}: boom")
    return {
        "report_version": 1,
        "region": label,
        "built_at": "2026-11-01T03:00:00Z",
        "tools": {},
        "steps": steps,
        "validation": {"ok": not failures, "failures": failures},
    }


def base_report(pack_ids: list[str]) -> dict:
    ts = "2026-06-07T23:59:58Z"
    steps = [
        step(f"base-{p}", [output(f"base-{p}", "basemap", "pmtiles", ts=ts)]) for p in pack_ids
    ]
    return {
        "report_version": 1,
        "region": "base",
        "built_at": "2026-11-01T03:00:00Z",
        "tools": {},
        "steps": steps,
        "validation": {"ok": True, "failures": []},
    }


def write_dist(dist: Path, reports: dict[str, dict]) -> Path:
    for label, report in reports.items():
        d = dist / label
        d.mkdir(parents=True, exist_ok=True)
        (d / "build-report.json").write_text(json.dumps(report), encoding="utf-8")
    return dist
