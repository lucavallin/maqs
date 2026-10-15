"""Builds the test region against the live VersaTiles archives. Run with --run-network."""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from maqs.cli import main

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.mark.network
def test_test_region_builds_end_to_end(tmp_path):
    result = CliRunner().invoke(
        main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)]
    )
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is True
    by_name = {s["name"]: s for s in report["steps"]}
    basemap, terrain = by_name["basemap"]["outputs"][0], by_name["terrain"]["outputs"][0]
    assert basemap["compression"] == "gzip" and basemap["max_zoom"] == 14 and basemap["tiles"] > 20
    assert terrain["tile_type"] == "webp" and terrain["max_zoom"] == 12
    assert basemap["bytes"] + terrain["bytes"] < 5_000_000
