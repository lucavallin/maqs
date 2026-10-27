import json
from pathlib import Path

import pytest

from maqs.curvature.score import score_way
from maqs.curvature.step import CurvatureStep
from maqs.data_golden import build_golden, main
from maqs.geometry import decode_polyline, line_length_m
from maqs.osm import extract
from maqs.steps.base import run_step
from tests.golden_compare import golden_mismatch
from tests.step_fixtures import stub_tags_filter
from tests.test_steps_curvature import junction_network

FIXTURES = Path(__file__).resolve().parents[2] / "Tests" / "MaqsTestSupport" / "Fixtures" / "test"

TRACK_NAMES = ["circle-40m", "s-bend", "straight", "close-points", "two-points", "ring-20m"]


@pytest.fixture
def curvature(ctx, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A curvature file for a small T-junction network, written by the real step."""
    ways = {
        1: ([1, 2, 3, 4, 5], {"highway": "primary"}),
        2: ([3, 6], {"highway": "primary"}),
        3: ([3, 7, 8], {"highway": "primary"}),
    }
    fixture = junction_network(tmp_path, ways)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    stub_tags_filter(monkeypatch)
    result = run_step(CurvatureStep(), ctx)
    assert result.status == "built", result.error
    return ctx.out_dir / "test-curvature.v1.sqlite"


def test_golden_matches_the_pipeline(curvature: Path) -> None:
    golden = build_golden(curvature)
    assert golden["golden_version"] == 1
    assert golden["fixture"] == "test-curvature.v1.sqlite"
    segments = golden["segments"]
    assert [s["osm_way_id"] for s in segments] == [1, 2, 3]
    for segment in segments:
        coordinates = decode_polyline(segment["geometry"])
        assert segment["coordinates"] == [list(c) for c in coordinates]
        merged, score, corners = score_way(coordinates)
        analysis = segment["analysis"]
        assert analysis["merged"] == [list(c) for c in merged]
        assert analysis["score"] == score
        assert analysis["length_m"] == line_length_m(merged)
        assert [c["apex"] for c in analysis["corners"]] == [list(c.apex) for c in corners]
        assert [c["ordinal"] for c in analysis["corners"]] == list(range(len(corners)))
    assert [t["name"] for t in golden["tracks"]] == TRACK_NAMES


def test_tracks_hold_the_shapes_they_are_named_for(curvature: Path) -> None:
    by_name = {t["name"]: t for t in build_golden(curvature)["tracks"]}
    assert len(by_name["circle-40m"]["input"]) == 37
    assert by_name["circle-40m"]["input"][0] == by_name["circle-40m"]["input"][-1]
    assert len(by_name["s-bend"]["input"]) == 20
    assert {c["direction"] for c in by_name["s-bend"]["analysis"]["corners"]} == {"left", "right"}
    assert by_name["straight"]["analysis"]["corners"] == []
    assert by_name["straight"]["analysis"]["score"] == 0.0
    assert len(by_name["close-points"]["input"]) == 20
    assert by_name["two-points"]["analysis"]["corners"] == []
    assert 45 < by_name["two-points"]["analysis"]["length_m"] < 55
    assert len(by_name["ring-20m"]["input"]) == 9


def test_main_writes_sorted_json(curvature: Path, tmp_path: Path) -> None:
    out = tmp_path / "golden.json"
    assert main([str(curvature), str(out)]) == 0
    text = out.read_text()
    assert json.loads(text) == build_golden(curvature)
    assert text.endswith("\n")
    assert text == json.dumps(json.loads(text), sort_keys=True, indent=1) + "\n"


def test_the_committed_data_golden_matches_the_committed_fixture() -> None:
    # A curvature change without a run of scripts/update-data-golden.sh fails here, instead of
    # leaving the Swift tests comparing against stale values.
    committed = json.loads((FIXTURES / "data-golden.json").read_text(encoding="utf-8"))
    assert golden_mismatch(build_golden(FIXTURES / "test-curvature.v1.sqlite"), committed) is None
