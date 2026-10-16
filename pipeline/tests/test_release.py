import copy
import hashlib
from pathlib import Path

import pytest

from maqs.release import Asset, ReleaseError, carried_count, local_assets, release_notes
from tests.test_schemas import MANIFEST


def write_assets(dist: Path, manifest: dict) -> None:
    """Write a file for every entry of this manifest's release with the right bytes and sha256."""
    for region in manifest["regions"]:
        for entries in region["layers"].values():
            for e in entries:
                _write(dist / region["id"] / e["file"], e)
    for pack in manifest["base"]:
        for e in pack["layers"]["basemap"]:
            _write(dist / "base" / e["file"], e)


def _write(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = b"x" * entry["bytes"]
    path.write_bytes(data)
    entry["sha256"] = hashlib.sha256(data).hexdigest()


@pytest.fixture
def doc():
    return copy.deepcopy(MANIFEST)


def test_local_assets_lists_every_entry_of_this_release(tmp_path, doc):
    write_assets(tmp_path, doc)
    assets = local_assets(doc, tmp_path)
    expected = [e["file"] for r in doc["regions"] for es in r["layers"].values() for e in es]
    expected += [e["file"] for p in doc["base"] for e in p["layers"]["basemap"]]
    assert sorted(a.file for a in assets) == sorted(expected)
    assert all(
        isinstance(a, Asset) and a.path.exists() and a.bytes == a.path.stat().st_size
        for a in assets
    )


def test_missing_file_fails(tmp_path, doc):
    write_assets(tmp_path, doc)
    (tmp_path / "veneto" / "veneto-trails.v1.sqlite").unlink()
    with pytest.raises(ReleaseError, match="veneto-trails.v1.sqlite: missing"):
        local_assets(doc, tmp_path)


def test_wrong_size_and_wrong_sha_fail(tmp_path, doc):
    write_assets(tmp_path, doc)
    target = tmp_path / "veneto" / "veneto-places.v1.sqlite"
    target.write_bytes(b"y" * 1234)  # same size as the fixture entry, different content
    with pytest.raises(ReleaseError, match="veneto-places.v1.sqlite: sha256 mismatch"):
        local_assets(doc, tmp_path)
    target.write_bytes(b"short")
    with pytest.raises(ReleaseError, match=r"veneto-places.v1.sqlite: 5 bytes, manifest says 1234"):
        local_assets(doc, tmp_path)


def test_carried_entries_are_not_required_locally(tmp_path, doc):
    write_assets(tmp_path, doc)
    carried = copy.deepcopy(doc["regions"][0]["layers"]["curvature"][0])
    carried["url"] = carried["url"].replace("data-2026-11", "data-2026-10")
    doc["regions"][0]["layers"]["curvature"].append(carried)
    assets = local_assets(doc, tmp_path)  # does not raise; the carried file is on an older release
    assert sum(a.file == "veneto-curvature.v1.sqlite" for a in assets) == 1
    assert carried_count(doc) == 1


def test_release_notes_name_regions_layers_timestamps_and_carried(doc):
    text = release_notes(doc, carried=2)
    assert text.startswith("# Map data 2026-11")
    assert (
        "- veneto: basemap 2026-06-07T23:59:58Z, terrain n/a, trails 2026-10-31T20:21:00Z" in text
    )
    assert "base pack triveneto" in text and "2 entries carried from earlier releases" in text
