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
