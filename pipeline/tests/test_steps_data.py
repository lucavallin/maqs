from datetime import UTC, datetime
from pathlib import Path

from maqs.osm import extract
from maqs.steps.data import metadata_for


def test_metadata_for_dates_the_build_and_stamps_the_extract(ctx, monkeypatch):
    source = Path("/cache/geofabrik/europe-italy-nord-est-latest.osm.pbf")
    read: list[Path] = []

    def fake_timestamp(pbf):
        read.append(pbf)
        return "2026-10-06T20:21:06Z"

    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: source)
    monkeypatch.setattr(extract, "osm_timestamp", fake_timestamp)
    before = datetime.now(UTC).strftime("%Y-%m-%d")
    meta = metadata_for(ctx, "places")
    after = datetime.now(UTC).strftime("%Y-%m-%d")
    assert (meta.layer, meta.region, meta.osm_timestamp) == (
        "places",
        "test",
        "2026-10-06T20:21:06Z",
    )
    assert meta.data_date in {before, after}
    assert read == [source]


def test_metadata_for_uses_the_run_date_of_the_context(ctx, monkeypatch):
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: Path("/cache/x.osm.pbf"))
    monkeypatch.setattr(extract, "osm_timestamp", lambda pbf: None)
    ctx.data_date = "2000-01-01"
    assert metadata_for(ctx, "trails").data_date == "2000-01-01"
