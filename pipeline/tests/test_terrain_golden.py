import hashlib
import json
from pathlib import Path

import pytest

from maqs.osm.terrain_sampler import TerrainSampler
from maqs.pmtiles_reader import PMTilesArchive, zxy_to_tile_id
from maqs.terrain_golden import build_golden, main
from tests.helpers import write_pmtiles
from tests.test_terrain_sampler import terrarium_tile

FIXTURES = Path(__file__).resolve().parents[2] / "Tests" / "MaqsTestSupport" / "Fixtures" / "test"

TILE_IDS = [
    (0, 0, 0),
    (1, 0, 0),
    (1, 1, 1),
    (5, 17, 11),
    (12, 2187, 1455),
    (12, 4095, 4095),
    (26, 67108863, 0),
]


@pytest.fixture
def archive(tmp_path: Path) -> Path:
    return write_pmtiles(
        tmp_path / "terrain.pmtiles",
        tile_type=4,
        min_zoom=12,
        max_zoom=12,
        tile_compression=1,
        tile=terrarium_tile(lambda px, py: px + py / 4),
        tile_id=zxy_to_tile_id(12, 2187, 1455),
    )


def test_golden_matches_the_sampler(archive: Path) -> None:
    golden = build_golden(archive)
    assert golden["golden_version"] == 1
    assert golden["zoom"] == 12
    sampler = TerrainSampler(archive)
    points = golden["points"]
    assert len(points) == 25 * 25
    for point in points:
        assert point["elevation"] == sampler.elevation(point["lon"], point["lat"])
    assert any(p["elevation"] is not None for p in points)
    reader = PMTilesArchive(archive)
    assert golden["tiles"]
    for tile in golden["tiles"]:
        raw = reader.tile(tile["z"], tile["x"], tile["y"])
        assert raw is not None
        assert tile["sha256"] == hashlib.sha256(raw).hexdigest()
    assert [(t["z"], t["x"], t["y"]) for t in golden["tile_ids"]] == TILE_IDS
    for entry in golden["tile_ids"]:
        assert entry["id"] == zxy_to_tile_id(entry["z"], entry["x"], entry["y"])


def test_main_writes_sorted_json(archive: Path, tmp_path: Path) -> None:
    out = tmp_path / "golden.json"
    assert main([str(archive), str(out)]) == 0
    text = out.read_text()
    assert json.loads(text) == build_golden(archive)
    assert text.endswith("\n")
    assert text == json.dumps(json.loads(text), sort_keys=True, indent=1) + "\n"


def test_the_committed_golden_file_matches_the_committed_fixture() -> None:
    # A sampler or reader change without a run of scripts/update-terrain-golden.sh fails here,
    # instead of leaving the Swift tests comparing against stale values.
    committed = json.loads((FIXTURES / "terrain-golden.json").read_text(encoding="utf-8"))
    assert build_golden(FIXTURES / "test-terrain.v1.pmtiles") == committed
