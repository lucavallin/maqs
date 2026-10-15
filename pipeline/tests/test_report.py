import json
from datetime import UTC, datetime

from maqs.report import REPORT_VERSION, build_report, report_path, write_report
from maqs.steps.base import Anomaly, StepResult
from maqs.validate import OutputInfo


def info(name="test-basemap.pmtiles"):
    return OutputInfo(
        name,
        10,
        "ab" * 32,
        "mvt",
        0,
        14,
        26,
        "gzip",
        "© OSM",
        "2026-06-07T23:59:58Z",
        "https://download.versatiles.org/osm-landcover.versatiles",
        {"k": "v"},
    )


def test_report_shape():
    results = [
        StepResult("basemap", "built", 7.7, ["versatiles", "convert"], [info()]),
        StepResult("terrain", "failed", 1.0, [], [], error="boom"),
    ]
    report = build_report(
        "test",
        results,
        {"versatiles": "5.0.0", "pmtiles": "dev"},
        built_at=datetime(2026, 10, 8, 14, 2, 11, tzinfo=UTC),
    )
    assert report["report_version"] == REPORT_VERSION and report["region"] == "test"
    assert report["built_at"] == "2026-10-08T14:02:11Z"
    assert report["tools"] == {"versatiles": "5.0.0", "pmtiles": "dev"}
    basemap = report["steps"][0]
    assert basemap["status"] == "built" and basemap["seconds"] == 7.7
    assert basemap["command"] == ["versatiles", "convert"]
    out = basemap["outputs"][0]
    assert out["file"] == "test-basemap.pmtiles" and out["sha256"] == "ab" * 32
    assert out["tiles"] == 26
    assert out["attribution"] == "© OSM" and out["source_data_date"] == "2026-06-07T23:59:58Z"
    assert out["source"] == "https://download.versatiles.org/osm-landcover.versatiles"
    assert "metadata" not in out
    assert report["steps"][1]["error"] == "boom"
    assert report["validation"] == {"ok": False, "failures": ["terrain: boom"]}


def test_report_ok_when_nothing_failed():
    report = build_report("x", [StepResult("basemap", "skipped", 0.0, [], [info()])], {})
    assert report["validation"] == {"ok": True, "failures": []}


def test_write_report_is_json_and_atomic(tmp_path):
    path = report_path(tmp_path)
    write_report(path, {"a": 1})
    assert json.loads(path.read_text()) == {"a": 1}
    assert not (tmp_path / "build-report.json.tmp").exists()


def test_report_carries_rows_and_anomalies():
    sqlite_info = OutputInfo(
        file="test-trails.sqlite",
        bytes=10,
        sha256="ab" * 32,
        tile_type=None,
        min_zoom=None,
        max_zoom=None,
        tiles=None,
        compression=None,
        attribution="© OSM",
        source_data_date="2026-10-06T20:21:06Z",
        source=None,
        metadata={},
        rows={"trails": 3},
    )
    anomalies = [Anomaly("gap", "relation/1", "gap of 12 m")]
    result = StepResult(
        "trails", "built", 1.0, ["osmium"], [sqlite_info], anomalies=anomalies, anomaly_count=1
    )
    step = build_report("test", [result], {})["steps"][0]
    assert step["outputs"][0]["rows"] == {"trails": 3} and step["outputs"][0]["tile_type"] is None
    assert step["anomalies"] == [{"kind": "gap", "id": "relation/1", "message": "gap of 12 m"}]
    assert step["anomaly_count"] == 1
    tile = build_report("test", [StepResult("basemap", "built", 1.0, [], [info()])], {})
    assert "rows" not in tile["steps"][0]["outputs"][0]
    assert tile["steps"][0]["anomalies"] == [] and tile["steps"][0]["anomaly_count"] == 0
