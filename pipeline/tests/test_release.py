import copy
import hashlib
import re
from pathlib import Path

import pytest

from maqs.release import (
    Asset,
    ReleaseError,
    ReleaseStateError,
    carried_count,
    choose_previous,
    local_assets,
    release_notes,
)
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


def rel(
    tag: str,
    *,
    manifest: bool = True,
    draft: bool = False,
    prerelease: bool = False,
    created: str | None = None,
) -> dict:
    """One release as `gh api repos/<owner>/<repo>/releases` returns it (the fields used)."""
    assets = [{"name": "veneto-trails.v1.sqlite"}]
    if manifest:
        assets.append({"name": "manifest.json"})
    month = tag.removeprefix("data-") if re.fullmatch(r"data-\d{4}-\d{2}", tag) else "2026-01"
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "created_at": created or f"{month}-01T03:00:00Z",
        "assets": assets,
    }


THIS = "data-2026-11"


@pytest.mark.parametrize(
    ("releases", "expected", "warned"),
    [
        pytest.param([], None, [], id="no-releases"),
        pytest.param(
            [rel(THIS, manifest=False)],
            None,
            [f"{THIS} has no manifest.json"],
            id="only-this-tag-without-manifest",
        ),
        pytest.param(
            [rel(THIS, manifest=False), rel("data-2026-10")],
            "data-2026-10",
            [f"{THIS} has no manifest.json"],
            id="this-tag-newest-without-manifest",
        ),
        pytest.param(
            [rel(THIS, manifest=False), rel("data-2026-10", manifest=False), rel("data-2026-09")],
            "data-2026-09",
            [f"{THIS} has no manifest.json", "data-2026-10 has no manifest.json"],
            id="older-orphan-without-manifest-is-skipped",
        ),
        pytest.param(
            [rel("data-2026-09"), rel("data-2026-10"), rel("data-2026-08")],
            "data-2026-10",
            [],
            id="ordered-by-tag-name-not-list-order",
        ),
        pytest.param(
            [
                rel("data-2026-12", manifest=False, draft=True),
                rel("data-2026-10", draft=True),
                rel("data-2026-09", prerelease=True),
                rel("data-2026-08"),
            ],
            "data-2026-08",
            [],
            id="drafts-and-prereleases-ignored",
        ),
        pytest.param(
            [rel("data-2026-10"), rel("data-2026-07-hotfix", manifest=False), rel("data-ci")],
            "data-2026-10",
            [],
            id="non-monthly-tags-are-not-candidates",
        ),
        pytest.param(
            [rel("v2.0.0", manifest=False, created="2026-10-20T09:00:00Z"), rel("data-2026-10")],
            "data-2026-10",
            ["clients would see a non-data release as latest"],
            id="package-release-newest",
        ),
        pytest.param(
            [rel("v2.0.0", manifest=False, created="2026-09-20T09:00:00Z"), rel("data-2026-10")],
            "data-2026-10",
            [],
            id="older-package-release-is-fine",
        ),
    ],
)
def test_choose_previous(releases, expected, warned):
    tag, warnings = choose_previous(releases, THIS)
    assert tag == expected
    assert len(warnings) == len(warned)
    for text, warning in zip(warned, warnings, strict=True):
        assert text in warning


def test_choose_previous_warns_that_this_run_repairs_its_own_release():
    _, warnings = choose_previous([rel(THIS, manifest=False), rel("data-2026-10")], THIS)
    assert "this run" in warnings[0]


def test_choose_previous_says_an_older_orphan_was_never_seen():
    releases = [rel(THIS, manifest=False), rel("data-2026-10", manifest=False), rel("data-2026-09")]
    _, warnings = choose_previous(releases, THIS)
    assert "orphan" in warnings[1]


@pytest.mark.parametrize(
    ("release", "releases"),
    [
        pytest.param(THIS, [rel("data-2026-12", manifest=False), rel("data-2026-10")], id="later"),
        pytest.param(
            "data-2026-12", [rel(THIS, manifest=False), rel("data-2026-10")], id="earlier-month"
        ),
        pytest.param("data-2026-12", [rel(THIS, manifest=False)], id="no-manifest-anywhere"),
    ],
)
def test_choose_previous_refuses_a_newest_release_without_manifest(release, releases):
    newest = max(r["tag_name"] for r in releases)
    with pytest.raises(ReleaseStateError) as exc:
        choose_previous(releases, release)
    message = str(exc.value)
    assert f"latest data release {newest} has no manifest.json" in message
    assert "re-run that month" in message
    assert f"gh release delete {newest} --cleanup-tag" in message


@pytest.mark.parametrize(
    "releases",
    [
        pytest.param({"tag_name": THIS}, id="not-a-list"),
        pytest.param(None, id="null"),
        pytest.param(["data-2026-10"], id="not-an-object"),
        pytest.param([{"tag_name": "data-2026-10", "draft": False}], id="missing-fields"),
        pytest.param([{**rel("data-2026-10"), "assets": [{}]}], id="asset-without-name"),
        pytest.param([{**rel("data-2026-10"), "assets": None}], id="assets-not-a-list"),
    ],
)
def test_choose_previous_rejects_input_that_is_not_a_releases_list(releases):
    with pytest.raises(ReleaseStateError, match="releases"):
        choose_previous(releases, THIS)
