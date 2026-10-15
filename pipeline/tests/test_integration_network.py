"""Builds the test region against the live VersaTiles archives. Run with --run-network."""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from maqs.cli import main
from maqs.sqlite_out import open_readonly

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
# The repo's .cache/ (CI restores .cache/geofabrik), so the nord-est extract is downloaded once.
CACHE = REAL.parent.parent / ".cache"


@pytest.mark.network
def test_test_region_builds_end_to_end(tmp_path):
    result = CliRunner().invoke(
        main,
        [
            "--config",
            str(REAL),
            "build",
            "--region",
            "test",
            "--dist",
            str(tmp_path),
            "--cache",
            str(CACHE),
        ],
    )
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is True
    by_name = {s["name"]: s for s in report["steps"]}
    assert set(by_name) == {"basemap", "terrain", "trails", "places", "curvature"}
    basemap, terrain = by_name["basemap"]["outputs"][0], by_name["terrain"]["outputs"][0]
    assert basemap["compression"] == "gzip" and basemap["max_zoom"] == 14 and basemap["tiles"] > 20
    assert terrain["tile_type"] == "webp" and terrain["max_zoom"] == 12
    assert basemap["bytes"] + terrain["bytes"] < 5_000_000
    trails_db, trails_overlay = by_name["trails"]["outputs"]
    assert trails_overlay["tile_type"] == "mvt" and trails_overlay["min_zoom"] == 6
    # Ranges are ~60-200 % of the live counts (10 trails, 22 places, 136 segments, 623 corners).
    assert 6 <= trails_db["rows"]["trails"] <= 20
    # Terrain is built first in the same run, so trails must have sampled it.
    trails_kinds = by_name["trails"]["anomaly_kinds"]
    assert not {"terrain_missing", "terrain_unreadable"} & set(trails_kinds), trails_kinds
    conn = open_readonly(tmp_path / "test" / "test-trails.sqlite")
    try:
        query = "SELECT count(*) FROM trails WHERE ascent_m IS NOT NULL"
        with_ascent = conn.execute(query).fetchone()[0]
    finally:
        conn.close()
    assert with_ascent >= 8  # all 10 live trails had an ascent on 2026-10-15
    assert 15 <= by_name["places"]["outputs"][0]["rows"]["places"] <= 45
    curvature_rows = by_name["curvature"]["outputs"][0]["rows"]
    assert 80 <= curvature_rows["segments"] <= 280
    assert 400 <= curvature_rows["corners"] <= 1250
    for name in (
        "test-trails.sqlite",
        "test-trails.pmtiles",
        "test-places.sqlite",
        "test-places.pmtiles",
        "test-curvature.sqlite",
    ):
        assert (tmp_path / "test" / name).exists()
