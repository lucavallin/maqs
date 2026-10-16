# pipeline/tests/test_manifest.py
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from maqs.config import load_config
from maqs.manifest import (
    ATTRIBUTION,
    ManifestError,
    asset_url,
    build_manifest,
    carry_over,
    entry_from_output,
    read_report,
    write_manifest,
)
from maqs.schemas import validate
from tests.manifest_fixtures import base_report, output, region_report, write_dist

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
NOW = datetime(2026, 11, 1, 3, 12, 44, tzinfo=UTC)
REGIONS = ("triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige")


@pytest.fixture
def cfg():
    return load_config(REAL)


@pytest.fixture
def full_dist(tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["test"] = region_report("test")
    reports["base"] = base_report(["triveneto"])
    return write_dist(tmp_path / "dist", reports)


def test_asset_url_is_tag_pinned():
    assert asset_url("data-2026-11", "veneto-trails.v1.sqlite") == (
        "https://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-trails.v1.sqlite"
    )


def test_entry_from_output_maps_report_fields_and_marks_overlays():
    sqlite = entry_from_output(output("veneto", "trails", "sqlite", nbytes=42), "data-2026-11")
    assert sqlite == {
        "layer_schema_version": 1,
        "file": "veneto-trails.v1.sqlite",
        "url": asset_url("data-2026-11", "veneto-trails.v1.sqlite"),
        "bytes": 42,
        "sha256": "0123456789abcdef" * 4,
        "data_date": "2026-11-01",
        "osm_timestamp": "2026-10-31T20:21:00Z",
    }
    overlay = entry_from_output(output("veneto", "trails", "pmtiles"), "data-2026-11")
    assert overlay["role"] == "overlay"
    assert "role" not in entry_from_output(output("veneto", "basemap", "pmtiles"), "data-2026-11")


def test_build_manifest_assembles_every_region_and_base_pack(cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    validate(m, "manifest")
    assert m["manifest_version"] == 1 and m["release"] == "data-2026-11"
    assert m["created_at"] == "2026-11-01T03:12:44Z" and m["shortbread_version"] == "1.0"
    assert [r["id"] for r in m["regions"]] == list(REGIONS)  # regions.yaml order, fixture excluded
    veneto = next(r for r in m["regions"] if r["id"] == "veneto")
    assert veneto["name"] == {"it": "Veneto", "en": "Veneto"}
    assert veneto["bbox"] == [10.6231, 44.7923, 13.1021, 46.6806]
    assert set(veneto["layers"]) == {"basemap", "terrain", "trails", "places", "curvature"}
    trail_files = [e["file"] for e in veneto["layers"]["trails"]]
    assert trail_files == ["veneto-trails.v1.sqlite", "veneto-trails.v1.pmtiles"]
    assert veneto["layers"]["trails"][1]["role"] == "overlay"
    assert veneto["layers"]["terrain"][0]["osm_timestamp"] is None
    assert veneto["layers"]["basemap"][0]["osm_timestamp"] == "2026-06-07T23:59:58Z"
    base_output = output("base-triveneto", "basemap", "pmtiles", ts="2026-06-07T23:59:58Z")
    base_entry = entry_from_output(base_output, "data-2026-11")
    assert m["base"] == [
        {
            "id": "triveneto",
            "regions": ["triveneto"],
            "max_zoom": 10,
            "layers": {"basemap": [base_entry]},
        }
    ]
    assert [a["text"] for a in m["attribution"]] == [a["text"] for a in ATTRIBUTION]


def test_include_fixtures_adds_the_test_region(cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-12", include_fixtures=True, now=NOW)
    assert m["regions"][0]["id"] == "test"
    validate(m, "manifest")


def test_missing_region_report_fails_naming_it(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS if r != "veneto"}
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: build-report.json not found"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_failed_step_in_a_report_fails(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["veneto"] = region_report("veneto", fail="places")
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: build failed: places: boom"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_missing_layer_fails(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["veneto"] = region_report("veneto", drop="curvature")
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: layer curvature missing"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_missing_base_pack_fails_even_with_fixtures(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["test"] = region_report("test")
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="base-triveneto"):
        build_manifest(cfg, dist, "data-2026-11", include_fixtures=True, now=NOW)


def test_old_unversioned_files_are_not_picked_up(cfg, full_dist):
    (full_dist / "veneto" / "veneto-trails.sqlite").write_bytes(b"old")
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    files = {e["file"] for r in m["regions"] for layer in r["layers"].values() for e in layer}
    assert "veneto-trails.sqlite" not in files


def test_read_report_errors(tmp_path):
    with pytest.raises(ManifestError, match="veneto: build-report.json not found"):
        read_report(tmp_path, "veneto")


def test_carry_over_keeps_only_lower_versions_of_known_layers(cfg, full_dist):
    current = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    for r in current["regions"]:
        for e in r["layers"]["trails"]:
            e["layer_schema_version"] = 2
            e["file"] = e["file"].replace(".v1.", ".v2.")
            e["url"] = e["url"].replace(".v1.", ".v2.")
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    # a region no longer configured
    previous["regions"].append({**previous["regions"][0], "id": "gone"})
    merged = carry_over(current, previous)
    veneto = next(r for r in merged["regions"] if r["id"] == "veneto")
    versions = [e["layer_schema_version"] for e in veneto["layers"]["trails"]]
    assert versions == [2, 2, 1, 1]  # v2 sqlite+overlay first, then the carried v1 pair
    carried = veneto["layers"]["trails"][2]
    assert carried["url"].startswith(
        "https://github.com/lucavallin/maqs/releases/download/data-2026-11/"
    )
    places_versions = [e["layer_schema_version"] for e in veneto["layers"]["places"]]
    assert places_versions == [1, 1]  # same version: not carried
    assert {r["id"] for r in merged["regions"]} == set(REGIONS)
    validate(merged, "manifest")
    assert current is not merged
    assert current["regions"][1]["layers"]["trails"][0]["layer_schema_version"] == 2


def test_build_manifest_applies_previous(cfg, full_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-10", now=NOW)
    m = build_manifest(cfg, full_dist, "data-2026-11", previous=previous, now=NOW)
    # identical versions: nothing carried, no duplicates
    assert all(len(r["layers"]["trails"]) == 2 for r in m["regions"])


def test_write_manifest_is_atomic_and_pretty(tmp_path, cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    out = tmp_path / "out" / "manifest.json"
    write_manifest(out, m)
    assert json.loads(out.read_text()) == m
    assert out.read_text().endswith("}\n") and not (out.parent / "manifest.json.tmp").exists()


def test_attribution_strings_match_data_license():
    licence = (Path(__file__).resolve().parents[2] / "DATA_LICENSE.md").read_text(encoding="utf-8")
    for a in ATTRIBUTION:
        assert a["text"] in licence, a["text"]
