import json
import subprocess
from pathlib import Path

import osmium
import osmium.osm.mutable as mutable
import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.osm import extract
from maqs.places.step import (
    PLACE_FILTERS,
    PlacesStep,
    parse_ele,
    place_kind,
    rank_score,
    read_places,
)
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from tests.helpers import write_pmtiles

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.mark.parametrize(
    "tags, kind",
    [
        ({"natural": "peak", "name": "Col Visentin"}, "peak"),
        ({"natural": "peak"}, "peak"),  # unnamed peaks are kept
        ({"natural": "volcano"}, "volcano"),
        ({"natural": "saddle"}, "saddle"),
        ({"natural": "saddle", "mountain_pass": "yes"}, "pass"),
        ({"mountain_pass": "yes"}, "pass"),
        ({"tourism": "alpine_hut"}, "alpine_hut"),
        ({"tourism": "wilderness_hut"}, "wilderness_hut"),
        ({"amenity": "shelter"}, "shelter"),
        ({"place": "village", "name": "Nevegal"}, "village"),
        ({"place": "hamlet", "name": "X"}, "hamlet"),
        ({"place": "isolated_dwelling", "name": "X"}, "isolated_dwelling"),
        ({"place": "village"}, None),  # unnamed settlements are skipped
        ({"place": "town", "name": "Belluno"}, None),
        ({"highway": "bus_stop"}, None),
    ],
)
def test_place_kind(tags, kind):
    assert place_kind(tags) == kind


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("1763", (1763.0, None)),
        ("1763.5 m", (1763.5, None)),
        (" 1,763 ", (1763.0, None)),
        ("1,500 m", (1500.0, None)),
        ("1763m", (1763.0, None)),
        (None, (None, None)),
        ("ca. 1700", (None, "unparsable ele 'ca. 1700'")),
        ("5000 ft", (None, "unparsable ele '5000 ft'")),
    ],
)
def test_parse_ele(raw, expected):
    assert parse_ele(raw) == expected


def test_rank_score():
    assert rank_score("Q123", 1763.0) == 2763.0
    assert rank_score(None, 1763.0) == 1763.0
    assert rank_score("Q1", None) == 1000.0
    assert rank_score(None, None) == 0.0


def test_place_filters_cover_the_brief():
    assert PLACE_FILTERS == (
        "n/natural=peak,volcano,saddle",
        "n/mountain_pass=yes",
        "n/tourism=alpine_hut,wilderness_hut",
        "n/amenity=shelter",
        "n/place=village,hamlet,isolated_dwelling",
    )


def write_places(tmp_path):
    path = tmp_path / "places.osm.pbf"
    with osmium.SimpleWriter(str(path), overwrite=True) as w:
        w.add_node(
            mutable.Node(
                id=1,
                location=(12.25, 46.10),
                tags={
                    "natural": "peak",
                    "name": "Col Visentin",
                    "name:de": "Visentin",
                    "ele": "1763",
                    "wikidata": "Q123",
                },
            )
        )
        w.add_node(
            mutable.Node(
                id=2,
                location=(12.26, 46.11),
                tags={
                    "natural": "saddle",
                    "mountain_pass": "yes",
                    "name": "Forcella",
                    "ele": "1,500 m",
                },
            )
        )
        w.add_node(mutable.Node(id=3, location=(12.27, 46.12), tags={"place": "hamlet"}))
        w.add_node(
            mutable.Node(
                id=4,
                location=(12.28, 46.13),
                tags={
                    "tourism": "alpine_hut",
                    "name": "Rifugio Brigata Cadore",
                    "ele": "ca. 1600",
                },
            )
        )
    return path


def test_read_places(tmp_path):
    records = {r.osm_id: r for r in read_places(write_places(tmp_path))}
    assert set(records) == {1, 2, 4}
    peak = records[1]
    assert (peak.kind, peak.name, peak.name_de, peak.ele, peak.wikidata, peak.rank_score) == (
        "peak",
        "Col Visentin",
        "Visentin",
        1763.0,
        "Q123",
        2763.0,
    )
    assert (records[2].kind, records[2].ele, records[2].rank_score) == ("pass", 1500.0, 1500.0)
    assert records[4].ele is None and records[4].rank_score == 0.0
    assert records[4].anomalies[0].kind == "ele"
    assert (peak.lon, peak.lat) == (12.25, 46.10)


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("test"),
    )


def test_build_writes_sqlite_and_overlay(ctx, tmp_path, monkeypatch):
    fixture = write_places(tmp_path)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    filtered = {}

    def fake_tags_filter(src, dst, expressions):
        filtered["expressions"] = list(expressions)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        return ["osmium", "tags-filter"]

    monkeypatch.setattr(extract, "tags_filter", fake_tags_filter)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))
    captured = {}

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        lines = Path(argv[-1]).read_text().splitlines()
        captured["features"] = [json.loads(line) for line in lines if line.strip()]
        write_pmtiles(Path(argv[argv.index("-o") + 1]), tile_type=1, min_zoom=8, max_zoom=14)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(tools, "run", fake_run)
    result = run_step(PlacesStep(), ctx)
    assert result.status == "built", result.error
    assert filtered["expressions"] == list(PLACE_FILTERS)
    conn = open_readonly(ctx.out_dir / "test-places.sqlite")
    rows = conn.execute(
        "SELECT osm_id, kind, name, ele, rank_score FROM places ORDER BY rank_score DESC"
    ).fetchall()
    assert rows == [
        (1, "peak", "Col Visentin", 1763.0, 2763.0),
        (2, "pass", "Forcella", 1500.0, 1500.0),
        (4, "alpine_hut", "Rifugio Brigata Cadore", None, 0.0),
    ]
    match = conn.execute(
        "SELECT osm_id FROM places p JOIN places_fts f ON f.rowid = p.id "
        "WHERE places_fts MATCH 'visentin'"
    ).fetchall()
    assert match == [(1,)]
    inside = conn.execute(
        "SELECT id FROM places_rtree "
        "WHERE min_lon <= 12.25 AND max_lon >= 12.25 AND min_lat <= 46.10 AND max_lat >= 46.10"
    ).fetchall()
    assert inside == [(1,)]
    assert [f["properties"]["kind"] for f in captured["features"]] == [
        "peak",
        "pass",
        "alpine_hut",
    ]
    assert captured["features"][0]["geometry"] == {"type": "Point", "coordinates": [12.25, 46.1]}
    assert {a.kind for a in result.anomalies} == {"ele"}
    assert result.outputs[0].rows == {"places": 3}
