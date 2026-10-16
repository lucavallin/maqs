# pipeline/tests/test_manifest.py
import copy
import json
from datetime import UTC, datetime, timedelta, timezone
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


def test_regions_option_selects_exactly_those_regions(cfg, full_dist):
    only = build_manifest(cfg, full_dist, "data-ci", regions=["test"], now=NOW)
    assert [r["id"] for r in only["regions"]] == ["test"] and only["release"] == "data-ci"
    assert len(only["base"]) == 1
    validate(only, "manifest")
    both = build_manifest(cfg, full_dist, "data-ci", regions=["veneto", "test"], now=NOW)
    assert [r["id"] for r in both["regions"]] == ["test", "veneto"]  # regions.yaml order
    with pytest.raises(ManifestError, match="unknown region 'nope'"):
        build_manifest(cfg, full_dist, "data-ci", regions=["nope"], now=NOW)


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
        build_manifest(cfg, dist, "data-2026-11", regions=["test"], now=NOW)


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
    snapshot_current, snapshot_previous = copy.deepcopy(current), copy.deepcopy(previous)
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
    assert current == snapshot_current
    assert previous == snapshot_previous
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


def _reports(**overrides):
    reports = {r: region_report(r) for r in REGIONS}
    reports["base"] = base_report(["triveneto"])
    reports.update(overrides)
    return reports


def _trails_step(report):
    return next(s for s in report["steps"] if s["name"] == "trails")


def test_entries_are_sorted_sqlite_before_overlay_whatever_the_report_order(cfg, tmp_path):
    report = region_report("veneto")
    _trails_step(report)["outputs"].reverse()
    dist = write_dist(tmp_path / "dist", _reports(veneto=report))
    m = build_manifest(cfg, dist, "data-2026-11", now=NOW)
    veneto = next(r for r in m["regions"] if r["id"] == "veneto")
    assert [e["file"] for e in veneto["layers"]["trails"]] == [
        "veneto-trails.v1.sqlite",
        "veneto-trails.v1.pmtiles",
    ]


def _v2(entries):
    out = copy.deepcopy(entries)
    for e in out:
        e["layer_schema_version"] = 2
        e["file"] = e["file"].replace(".v1.", ".v2.")
        e["url"] = e["url"].replace(".v1.", ".v2.")
    return out


def test_carry_over_orders_files_even_when_inputs_arrive_unsorted(cfg, full_dist):
    current = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    for manifest in (current, previous):
        veneto = next(r for r in manifest["regions"] if r["id"] == "veneto")
        veneto["layers"]["trails"].reverse()
    veneto = next(r for r in current["regions"] if r["id"] == "veneto")
    veneto["layers"]["trails"] = _v2(veneto["layers"]["trails"])
    merged = carry_over(current, previous)
    merged_veneto = next(r for r in merged["regions"] if r["id"] == "veneto")
    assert [e["file"] for e in merged_veneto["layers"]["trails"]] == [
        "veneto-trails.v2.sqlite",
        "veneto-trails.v2.pmtiles",
        "veneto-trails.v1.sqlite",
        "veneto-trails.v1.pmtiles",
    ]


def test_carry_over_ignores_previous_entries_with_a_higher_version(cfg, full_dist):
    current = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    for r in previous["regions"]:
        r["layers"]["trails"] = _v2(r["layers"]["trails"])
    merged = carry_over(current, previous)
    assert merged == current


def test_carry_over_applies_to_base_packs(cfg, full_dist):
    current = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    current["base"][0]["layers"]["basemap"] = _v2(current["base"][0]["layers"]["basemap"])
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    merged = carry_over(current, previous)
    assert [e["file"] for e in merged["base"][0]["layers"]["basemap"]] == [
        "base-triveneto-basemap.v2.pmtiles",
        "base-triveneto-basemap.v1.pmtiles",
    ]
    validate(merged, "manifest")


def test_naive_now_is_rejected_and_aware_now_is_normalised_to_utc(cfg, full_dist):
    with pytest.raises(ValueError, match="timezone-aware"):
        build_manifest(cfg, full_dist, "data-2026-11", now=datetime(2026, 11, 1, 3, 0, 0))
    plus_two = timezone(timedelta(hours=2))
    m = build_manifest(
        cfg, full_dist, "data-2026-11", now=datetime(2026, 11, 1, 5, 12, 44, tzinfo=plus_two)
    )
    assert m["created_at"] == "2026-11-01T03:12:44Z"


def test_unversioned_report_output_asks_for_a_rebuild(cfg, tmp_path):
    report = region_report("veneto")
    del _trails_step(report)["outputs"][0]["layer_schema_version"]
    dist = write_dist(tmp_path / "dist", _reports(veneto=report))
    with pytest.raises(ManifestError, match="veneto: build-report.json predates the versioned"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_truncated_report_is_a_manifest_error(cfg, tmp_path):
    dist = write_dist(tmp_path / "dist", _reports())
    (dist / "veneto" / "build-report.json").write_text('{"steps": [', encoding="utf-8")
    with pytest.raises(ManifestError, match="veneto: build-report.json: "):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_base_pack_with_a_non_basemap_output_fails(cfg, tmp_path):
    base = base_report(["triveneto"])
    base["steps"][0]["outputs"][0]["layer"] = "terrain"
    dist = write_dist(tmp_path / "dist", _reports(base=base))
    with pytest.raises(ManifestError, match="base-triveneto: unexpected layer terrain"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_base_pack_step_missing_from_the_report_fails(cfg, tmp_path):
    dist = write_dist(tmp_path / "dist", _reports(base=base_report([])))
    with pytest.raises(ManifestError, match="base-triveneto: not built"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_manifest_attribution_does_not_alias_the_constant(cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    m["attribution"][0]["layers"].append("mutated")
    assert "mutated" not in ATTRIBUTION[0]["layers"]


def _at_version(entries, version):
    out = copy.deepcopy(entries)
    for e in out:
        old, new = f".v{e['layer_schema_version']}.", f".v{version}."
        e["layer_schema_version"] = version
        e["file"] = e["file"].replace(old, new)
        e["url"] = e["url"].replace(old, new)
    return out


def _release(cfg, dist, release, trails_version):
    """A freshly built manifest whose trails are at `trails_version` in every region."""
    m = build_manifest(cfg, dist, release, now=NOW)
    for r in m["regions"]:
        r["layers"]["trails"] = _at_version(r["layers"]["trails"], trails_version)
    return m


def _trails(manifest):
    """(version, release tag in the url) of veneto's trails entries, in manifest order."""
    veneto = next(r for r in manifest["regions"] if r["id"] == "veneto")
    return [
        (e["layer_schema_version"], e["url"].split("/")[-2]) for e in veneto["layers"]["trails"]
    ]


def test_carry_over_ends_the_window_after_one_release(cfg, full_dist):
    october = _release(cfg, full_dist, "data-2026-10", 1)
    november = carry_over(_release(cfg, full_dist, "data-2026-11", 2), october)
    assert _trails(november) == [
        (2, "data-2026-11"),
        (2, "data-2026-11"),
        (1, "data-2026-10"),
        (1, "data-2026-10"),
    ]
    december = carry_over(_release(cfg, full_dist, "data-2026-12", 2), november)
    assert _trails(december) == [(2, "data-2026-12"), (2, "data-2026-12")]
    validate(december, "manifest")


def test_a_same_month_rerun_keeps_the_entries_that_month_carried(cfg, full_dist):
    october = _release(cfg, full_dist, "data-2026-10", 1)
    november = carry_over(_release(cfg, full_dist, "data-2026-11", 2), october)
    rerun = carry_over(_release(cfg, full_dist, "data-2026-11", 2), november)
    assert _trails(rerun) == _trails(november)
    assert rerun["regions"] == november["regions"]


def test_a_double_bump_carries_only_the_previous_release_version(cfg, full_dist):
    october = _release(cfg, full_dist, "data-2026-10", 1)
    november = carry_over(_release(cfg, full_dist, "data-2026-11", 2), october)
    december = carry_over(_release(cfg, full_dist, "data-2026-12", 3), november)
    assert _trails(december) == [
        (3, "data-2026-12"),
        (3, "data-2026-12"),
        (2, "data-2026-11"),
        (2, "data-2026-11"),
    ]


def test_a_rollback_to_a_lower_version_carries_nothing(cfg, full_dist):
    october = _release(cfg, full_dist, "data-2026-10", 1)
    november = carry_over(_release(cfg, full_dist, "data-2026-11", 2), october)
    december = _release(cfg, full_dist, "data-2026-12", 1)
    assert carry_over(december, november) == december


@pytest.fixture
def bumped_dist(tmp_path):
    """Every region and the base pack built, with veneto's trails at schema version 2."""
    veneto = region_report("veneto")
    for o in _trails_step(veneto)["outputs"]:
        o["layer_schema_version"] = 2
        o["file"] = o["file"].replace(".v1.", ".v2.")
    return write_dist(tmp_path / "bumped", _reports(veneto=veneto))


def test_a_previous_manifest_failing_the_schema_is_refused(cfg, full_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-10", now=NOW)
    previous["release"] = "latest"
    with pytest.raises(ManifestError, match="previous manifest: /release: "):
        build_manifest(cfg, full_dist, "data-2026-11", previous=previous, now=NOW)


def test_a_dated_release_refuses_a_data_ci_previous(cfg, full_dist):
    previous = build_manifest(cfg, full_dist, "data-ci", regions=list(REGIONS), now=NOW)
    with pytest.raises(ManifestError, match="previous manifest data-ci"):
        build_manifest(cfg, full_dist, "data-2026-11", previous=previous, now=NOW)


def test_a_dated_release_refuses_a_later_previous_but_takes_the_same_month(cfg, full_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    with pytest.raises(ManifestError, match="previous manifest data-2026-12"):
        build_manifest(cfg, full_dist, "data-2026-11", previous=previous, now=NOW)
    same = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    build_manifest(cfg, full_dist, "data-2026-11", previous=same, now=NOW)


def test_a_carried_url_that_does_not_name_its_file_fails(cfg, full_dist, bumped_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-10", now=NOW)
    veneto = next(r for r in previous["regions"] if r["id"] == "veneto")
    veneto["layers"]["trails"][0]["url"] = asset_url("data-2026-10", "veneto-places.v1.sqlite")
    with pytest.raises(ManifestError, match=r"veneto: trails: url .* does not name veneto-trails"):
        build_manifest(cfg, bumped_dist, "data-2026-11", previous=previous, now=NOW)


def test_a_dated_release_never_carries_a_data_ci_url(cfg, full_dist, bumped_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    veneto = next(r for r in previous["regions"] if r["id"] == "veneto")
    for e in veneto["layers"]["trails"]:
        e["url"] = e["url"].replace("/data-2026-11/", "/data-ci/")
    with pytest.raises(
        ManifestError, match="veneto: trails: veneto-trails.v1.sqlite points at data-ci"
    ):
        build_manifest(cfg, bumped_dist, "data-2026-11", previous=previous, now=NOW)


def test_a_report_written_for_another_region_is_refused(cfg, tmp_path):
    misplaced = region_report("veneto")
    misplaced["region"] = "triveneto"
    dist = write_dist(tmp_path / "dist", _reports(veneto=misplaced))
    with pytest.raises(ManifestError, match="veneto: build-report.json belongs to 'triveneto'"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)
    base = base_report(["triveneto"])
    base["region"] = "veneto"
    dist = write_dist(tmp_path / "dist2", _reports(base=base))
    with pytest.raises(ManifestError, match="base: build-report.json belongs to 'veneto'"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_an_output_named_for_another_region_is_refused(cfg, tmp_path):
    report = region_report("veneto")
    _trails_step(report)["outputs"][0]["file"] = "triveneto-trails.v1.sqlite"
    dist = write_dist(tmp_path / "dist", _reports(veneto=report))
    with pytest.raises(
        ManifestError, match="veneto: output triveneto-trails.v1.sqlite does not belong"
    ):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_a_base_pack_output_named_for_another_pack_is_refused(cfg, tmp_path):
    base = base_report(["triveneto"])
    base["steps"][0]["outputs"][0]["file"] = "base-dolomiti-basemap.v1.pmtiles"
    dist = write_dist(tmp_path / "dist", _reports(base=base))
    with pytest.raises(
        ManifestError, match="base-triveneto: output base-dolomiti-basemap.v1.pmtiles does not"
    ):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)
