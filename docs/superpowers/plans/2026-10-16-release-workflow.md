# Release Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `build-maps.yml`, the monthly/dispatch workflow that downloads the Geofabrik extract once, builds every region and the base pack in a matrix, assembles and validates `manifest.json`, and publishes the `data-YYYY-MM` release marked latest — never a partial latest, safe re-runs, pinned actions, default token only — plus the three small CLI commands that keep its logic testable.

**Architecture:** The workflow is thin shell around four CLI calls. `maqs regions --json` gives the matrix; `maqs fetch` warms the md5-keyed extract cache in `prepare`; `maqs build` runs per matrix target and uploads `dist/<target>` as an artifact; the `release` job (full runs only) downloads the artifacts and the latest published manifest, runs `maqs manifest --previous`, then `maqs release-check` (every asset the new manifest names for this tag exists with the right bytes and sha256; writes the notes), then `gh release create|upload --clobber|edit --latest`, uploading `manifest.json` last.

**Tech Stack:** GitHub Actions (`ubuntu-24.04`; `actions/checkout@v7`, `actions/cache@v6`, `actions/upload-artifact@v7`, `actions/download-artifact@v7`, `astral-sh/setup-uv@v7`), `gh` 2.x on the runner, the existing `maqs` package (`click`, `jsonschema`), PyYAML (test-only, via `uv run --with` or the dev group) for the workflow assertions.

**Spec:** `docs/superpowers/specs/2026-10-16-release-workflow-design.md`

## Global Constraints

- Only a FULL run (cron, or dispatch with `region` and `layers` both empty) runs the `release` job; subset runs build and upload artifacts only. `permissions: contents: read` at the top, `contents: write` on the `release` job only; only `GITHUB_TOKEN`; `concurrency: { group: build-maps, cancel-in-progress: false }`; `ubuntu-24.04` everywhere; every `uses:` pinned to the major tags already in `pipeline.yml`.
- One Geofabrik download per run: `actions/cache` on `.cache/geofabrik` keyed `geofabrik-<extract-name>-<md5>` (`extract_name("europe/italy/nord-est") == "europe-italy-nord-est"`), warmed in `prepare` by `maqs fetch`, restored in every `build` job.
- Release tag `data-YYYY-MM` from the run's UTC date; `gh release create <tag> --target "$GITHUB_SHA" --title "Map data YYYY-MM" --notes-file notes.md` only when `gh release view <tag>` fails; assets uploaded with `--clobber`; `manifest.json` uploaded LAST; `gh release edit <tag> --latest` always. Nothing is ever deleted from a release.
- `maqs manifest` is called with `--previous` only when the latest release has a `manifest.json` asset (`gh release download --pattern manifest.json --dir previous`); a missing release or asset means no `--previous`.
- `maqs release-check` fails (exit 1) when any manifest entry whose URL tag equals the manifest's `release` is missing from `dist/` or differs in `bytes` or `sha256`; entries with an older tag (carried) are not required locally; `--notes PATH` writes the release notes (one line per region with its layers' `osm_timestamp`s, the base packs, the carried count).
- `maqs regions --json` prints `{"regions": [{"id", "fixture", "name": {"it","en"}, "bbox", "geofabrik"}], "base_packs": [{"id", "regions", "max_zoom"}], "geofabrik_extracts": [...]}`; the plain output is unchanged.
- `maqs fetch --extract <name> [--cache DIR]` downloads and md5-verifies one extract into `<cache>/geofabrik/` through the same code `maqs build` uses (`FetchError` → exit 1); does nothing when the file exists.
- Disk: `prepare` fails when less than 6 GB is free on `/` (measured need about 3 GB).
- The base pack target `base` is in the matrix only on a full run or when `region == base`.
- Every CLI call via `maqs.tools.run`; unit tests never touch the network (autouse guard), never run `gh`, never run a build; the workflow YAML is parsed in a test. Ruff (line-length 100; select E,F,I,B,UP,SIM,PTH) clean, no suppressions; conventional commits; no attribution trailer; nothing generated committed.
- `swift.yml` is NOT part of this plan (Phase 4; `CONTRADICTS BRIEF` minor, ADR 0013).
- The first full run publishes `data-2026-10` for real: it runs only in Task 7, after Task 5's subset run is green, and only on the owner's explicit go at that step.

## Review Focus

1. **The manifest names a file that is not in `dist/`** (a build job's artifact missing or renamed). Expected: `release-check` exits 1 naming the file; nothing is uploaded. Test in Task 3.
2. **A carried entry (older tag) is absent locally.** Expected: `release-check` ignores it (it lives on an older release) and succeeds. Test in Task 3.
3. **No release exists yet, or the latest release has no `manifest.json` asset** (a half-published first run). Expected: the release job proceeds without `--previous`. Task 4's shell handles both (`|| true` plus a file-existence test); a unit test cannot run `gh`, so Task 5's live subset run cannot prove it either — the first full run (Task 7) is the live proof; the shell is reviewed in Task 4.
4. **A dispatch names an unknown or fixture region.** Expected: `prepare` fails with the valid ids before any download. Task 1 gives `regions --json` the data; Task 4's jq step does the check; test in Task 1 that fixtures are flagged and ids are exact.
5. **A dispatch with `layers` only** (every region, some layers). Expected: builds every region with that subset, uploads artifacts, does not publish (`full` is false). Task 4; checked live in Task 5 together with the `region: test` dispatch (one dispatch with `region: test`, which exercises the same `full == false` path).

---

### Task 1: `maqs regions --json`

**Files:**
- Modify: `pipeline/src/maqs/cli.py` (the `regions` command), `pipeline/tests/test_cli.py`

**Interfaces:**
- Consumes: `Config` (`regions`, `base_packs`, `geofabrik_extracts()`), `Region` (`id`, `fixture`, `name`, `bbox`, `osm`), `BasePack`.
- Produces: `regions --json` output exactly as in Global Constraints; `regions_json(cfg: Config) -> dict` helper in `cli.py` used by the command.

- [ ] **Step 1: Write the failing test**

Append to `pipeline/tests/test_cli.py`:

```python
def test_regions_json_lists_regions_base_packs_and_extracts():
    result = CliRunner().invoke(main, ["--config", str(REAL), "regions", "--json"])
    assert result.exit_code == 0, result.output
    doc = json.loads(result.output)
    ids = [r["id"] for r in doc["regions"]]
    assert ids == ["test", "triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige"]
    test = doc["regions"][0]
    assert test["fixture"] is True and test["geofabrik"] == "europe/italy/nord-est"
    assert test["name"] == {"it": "Nevegal (test)", "en": "Nevegal (test)"}
    assert test["bbox"] == [12.21, 46.08, 12.29, 46.13]
    assert all(r["fixture"] is False for r in doc["regions"][1:])
    assert doc["base_packs"] == [{"id": "triveneto", "regions": ["triveneto"], "max_zoom": 10}]
    assert doc["geofabrik_extracts"] == ["europe/italy/nord-est"]
    assert [r["id"] for r in doc["regions"] if not r["fixture"]] == ids[1:]
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pipeline/`): `uv run pytest tests/test_cli.py -k regions_json -q`
Expected: FAIL with `No such option: --json` (exit code 2 in `result.output`).

- [ ] **Step 3: Implement**

In `pipeline/src/maqs/cli.py`:

```python
def regions_json(cfg: Config) -> dict:
    """The machine-readable region list the release workflow builds its matrix from."""
    return {
        "regions": [
            {
                "id": r.id,
                "fixture": r.fixture,
                "name": {"it": r.name["it"], "en": r.name["en"]},
                "bbox": list(r.bbox),
                "geofabrik": (r.osm or {}).get("geofabrik"),
            }
            for r in cfg.regions
        ],
        "base_packs": [
            {"id": p.id, "regions": list(p.regions), "max_zoom": p.max_zoom} for p in cfg.base_packs
        ],
        "geofabrik_extracts": cfg.geofabrik_extracts(),
    }


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output for the workflows.")
@click.pass_context
def regions(ctx: click.Context, as_json: bool) -> None:
    """List configured regions, their OSM extracts, and the base packs."""
    cfg = _load(_config_path(ctx))
    if as_json:
        click.echo(json.dumps(regions_json(cfg), ensure_ascii=False))
        return
    … (existing plain output unchanged)
```

- [ ] **Step 4: Run the tests, lint, commit**

Run: `uv run pytest tests/test_cli.py -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

```bash
git add pipeline/src/maqs/cli.py pipeline/tests/test_cli.py
git commit -m "feat(pipeline): maqs regions --json for the release workflow's matrix"
```

---

### Task 2: `maqs fetch`

**Files:**
- Modify: `pipeline/src/maqs/osm/extract.py` (split `geofabrik_pbf`), `pipeline/src/maqs/cli.py`, `pipeline/tests/test_osm_extract.py`, `pipeline/tests/test_cli.py`

**Interfaces:**
- Consumes: `extract.geofabrik_pbf(ctx)`, `download`, `md5_of`, `parse_md5_sidecar`, `FetchError`, `extract_name`, `GEOFABRIK_BASE`.
- Produces: `extract.fetch_extract(cache: Path, extract: str) -> Path` — the body of today's `geofabrik_pbf` minus the region lookup; `geofabrik_pbf(ctx)` becomes `return fetch_extract(ctx.cache, region_extract_id(ctx))`. CLI `fetch --extract NAME [--cache DIR]` (default cache `<repo root>/.cache`), prints `ok: <path> (<bytes> bytes)`; `FetchError` → `ClickException` (exit 1); an extract not listed in `regions.yaml` → `UsageError` (exit 2) listing the known extracts.

- [ ] **Step 1: Write the failing tests**

In `pipeline/tests/test_osm_extract.py` (reuse the module's existing download stubs; `fake_download(url, dest, **kw)` writes bytes and the md5 sidecar as the existing `geofabrik_pbf` tests do):

```python
def test_fetch_extract_downloads_once_and_reuses(tmp_path, monkeypatch, fake_download):
    cache = tmp_path / "cache"
    path = extract.fetch_extract(cache, "europe/italy/nord-est")
    assert path == cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"
    assert path.exists() and fake_download.calls == 2  # sidecar + file
    assert extract.fetch_extract(cache, "europe/italy/nord-est") == path
    assert fake_download.calls == 2  # reused, not downloaded again
```

(Adapt to the fixture names the file already uses; the existing `geofabrik_pbf` tests must keep passing unchanged.)

In `pipeline/tests/test_cli.py`:

```python
def test_fetch_downloads_the_named_extract(monkeypatch, tmp_path):
    calls = []

    def fake_fetch(cache, extract):
        calls.append((cache, extract))
        p = cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"pbf")
        return p

    monkeypatch.setattr(cli.extract, "fetch_extract", fake_fetch)
    result = CliRunner().invoke(
        main, ["--config", str(REAL), "fetch", "--extract", "europe/italy/nord-est", "--cache", str(tmp_path)]
    )
    assert result.exit_code == 0, result.output
    assert calls == [(tmp_path, "europe/italy/nord-est")] and "ok:" in result.output and "3 bytes" in result.output


def test_fetch_rejects_an_unknown_extract(tmp_path):
    result = CliRunner().invoke(main, ["--config", str(REAL), "fetch", "--extract", "europe/nowhere", "--cache", str(tmp_path)])
    assert result.exit_code == 2 and "europe/italy/nord-est" in result.output


def test_fetch_reports_a_download_failure(monkeypatch, tmp_path):
    def boom(cache, extract):
        raise cli.extract.FetchError("md5 mismatch for x")

    monkeypatch.setattr(cli.extract, "fetch_extract", boom)
    result = CliRunner().invoke(main, ["--config", str(REAL), "fetch", "--extract", "europe/italy/nord-est", "--cache", str(tmp_path)])
    assert result.exit_code == 1 and "md5 mismatch" in result.output
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_osm_extract.py -k fetch_extract tests/test_cli.py -k fetch -q`
Expected: FAIL with `AttributeError: module 'maqs.osm.extract' has no attribute 'fetch_extract'` / `No such command 'fetch'`.

- [ ] **Step 3: Implement**

`pipeline/src/maqs/osm/extract.py`:

```python
def fetch_extract(cache: Path, extract: str) -> Path:
    """Download `<extract>-latest.osm.pbf` into the cache once, md5-verified; reuse it when present."""
    dest = cache / "geofabrik" / f"{extract_name(extract)}-latest.osm.pbf"
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{GEOFABRIK_BASE}/{extract}-latest.osm.pbf"
    md5_file = dest.with_suffix(dest.suffix + ".md5")
    download(f"{url}.md5", md5_file)
    expected = parse_md5_sidecar(md5_file.read_text(encoding="utf-8"))
    tmp = dest.with_suffix(dest.suffix + ".unverified")
    download(url, tmp)
    actual = md5_of(tmp)
    if actual != expected:
        tmp.unlink(missing_ok=True)
        md5_file.unlink(missing_ok=True)
        raise FetchError(f"md5 mismatch for {url}: expected {expected}, got {actual}")
    tmp.replace(dest)
    return dest


def geofabrik_pbf(ctx: BuildContext) -> Path:
    return fetch_extract(ctx.cache, region_extract_id(ctx))
```

(Keep whatever `mkdir` the current function does; move it, do not duplicate it.)

`pipeline/src/maqs/cli.py`:

```python
from maqs.osm import extract


@main.command()
@click.option("--extract", "extract_id", required=True, help="Geofabrik extract, e.g. europe/italy/nord-est.")
@click.option("--cache", type=click.Path(path_type=Path), default=None, show_default=".cache/ under the repo root")
@click.pass_context
def fetch(ctx: click.Context, extract_id: str, cache: Path | None) -> None:
    """Download one Geofabrik extract into the cache (md5-verified); reuse it when present."""
    config_path = _config_path(ctx)
    cfg = _load(config_path)
    known = cfg.geofabrik_extracts()
    if extract_id not in known:
        raise click.UsageError(f"unknown extract '{extract_id}'; configured: {', '.join(known)}")
    if cache is None:
        cache = _repo_root(config_path) / ".cache"
    try:
        path = extract.fetch_extract(cache, extract_id)
    except extract.FetchError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"ok: {path} ({path.stat().st_size} bytes)")
```

Module docstring: add `fetch`, `release-check`.

- [ ] **Step 4: Run the suite, lint, commit**

Run: `uv run pytest -q && uv run ruff format . && uv run ruff check .`
Expected: all pass (existing `geofabrik_pbf` tests unchanged and green).

```bash
git add pipeline/src/maqs/osm/extract.py pipeline/src/maqs/cli.py pipeline/tests
git commit -m "feat(pipeline): maqs fetch warms the Geofabrik cache without a region"
```

---

### Task 3: `maqs release-check`

**Files:**
- Create: `pipeline/src/maqs/release.py`, `pipeline/tests/test_release.py`
- Modify: `pipeline/src/maqs/cli.py`, `pipeline/tests/test_cli.py`

**Interfaces:**
- Consumes: `manifest.url_tag(url)`, `validate.sha256(path)`, `schemas.validate`, `SchemaError`.
- Produces (`release.py`): `@dataclass(frozen=True) Asset(file: str, path: Path, bytes: int)`; `class ReleaseError(ValueError)`; `local_assets(manifest: dict, dist: Path) -> list[Asset]` — every entry (regions and base) whose `url_tag(url) == manifest["release"]`, resolved to `dist/<label>/<file>` where `<label>` is the region id, or `base` for base packs; raises `ReleaseError("<file>: missing")`, `("<file>: <n> bytes, manifest says <m>")`, `("<file>: sha256 mismatch")`; `release_notes(manifest: dict, carried: int) -> str` — Markdown: title line, one bullet per region (`id`: layers with their `osm_timestamp` or `n/a`), base packs, `created_at`, `<carried> entries carried from earlier releases`; `carried_count(manifest) -> int` (entries whose tag ≠ release). CLI `release-check --dist DIR --manifest PATH [--notes PATH]`: validates the manifest against the schema first, prints one line per asset (`<file> <bytes>`) and `total <n> assets, <bytes> bytes`, writes the notes when asked; exit 1 on `ReleaseError`/`SchemaError`.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_release.py
import copy
import hashlib
import json
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
    assert all(isinstance(a, Asset) and a.path.exists() and a.bytes == a.path.stat().st_size for a in assets)


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
    assert "- veneto: basemap 2026-06-07T23:59:58Z, terrain n/a, trails 2026-10-31T20:21:00Z" in text
    assert "base pack triveneto" in text and "2 entries carried from earlier releases" in text
```

In `pipeline/tests/test_cli.py`:

```python
def test_release_check_passes_and_writes_notes(tmp_path):
    from tests.test_release import write_assets
    from tests.test_schemas import MANIFEST

    doc = json.loads(json.dumps(MANIFEST))
    write_assets(tmp_path / "dist", doc)
    (tmp_path / "manifest.json").write_text(json.dumps(doc))
    result = CliRunner().invoke(main, ["--config", str(REAL), "release-check", "--dist", str(tmp_path / "dist"),
                                       "--manifest", str(tmp_path / "manifest.json"), "--notes", str(tmp_path / "notes.md")])
    assert result.exit_code == 0, result.output
    assert "veneto-trails.v1.sqlite 1234" in result.output and "total " in result.output
    assert (tmp_path / "notes.md").read_text().startswith("# Map data 2026-11")


def test_release_check_fails_on_a_missing_asset(tmp_path):
    from tests.test_release import write_assets
    from tests.test_schemas import MANIFEST

    doc = json.loads(json.dumps(MANIFEST))
    write_assets(tmp_path / "dist", doc)
    (tmp_path / "dist" / "base" / "base-triveneto-basemap.v1.pmtiles").unlink()
    (tmp_path / "manifest.json").write_text(json.dumps(doc))
    result = CliRunner().invoke(main, ["--config", str(REAL), "release-check", "--dist", str(tmp_path / "dist"), "--manifest", str(tmp_path / "manifest.json")])
    assert result.exit_code == 1 and "base-triveneto-basemap.v1.pmtiles: missing" in result.output
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_release.py tests/test_cli.py -k release -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.release'`.

- [ ] **Step 3: Implement `release.py`**

```python
"""Pre-publish checks for a data release and its release notes (docs/architecture.md)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from maqs.manifest import url_tag
from maqs.validate import sha256


class ReleaseError(ValueError):
    """A file the manifest names for this release is missing or differs from the manifest."""


@dataclass(frozen=True)
class Asset:
    file: str
    path: Path
    bytes: int


def _entries(manifest: dict):
    for region in manifest["regions"]:
        for entries in region["layers"].values():
            for entry in entries:
                yield region["id"], entry
    for pack in manifest["base"]:
        for entry in pack["layers"]["basemap"]:
            yield "base", entry


def carried_count(manifest: dict) -> int:
    release = manifest["release"]
    return sum(1 for _, e in _entries(manifest) if url_tag(e["url"]) != release)


def local_assets(manifest: dict, dist: Path) -> list[Asset]:
    """Every file this release must upload, checked against the manifest's bytes and sha256."""
    release = manifest["release"]
    assets: list[Asset] = []
    for label, entry in _entries(manifest):
        if url_tag(entry["url"]) != release:
            continue  # carried from an earlier release; its file lives there
        path = dist / label / entry["file"]
        if not path.exists():
            raise ReleaseError(f"{entry['file']}: missing (expected at {path})")
        size = path.stat().st_size
        if size != entry["bytes"]:
            raise ReleaseError(f"{entry['file']}: {size} bytes, manifest says {entry['bytes']}")
        if sha256(path) != entry["sha256"]:
            raise ReleaseError(f"{entry['file']}: sha256 mismatch")
        assets.append(Asset(entry["file"], path, size))
    return assets


def release_notes(manifest: dict, carried: int) -> str:
    month = manifest["release"].removeprefix("data-")
    lines = [f"# Map data {month}", "", f"Built {manifest['created_at']}.", "", "## Regions", ""]
    for region in manifest["regions"]:
        parts = []
        for layer, entries in region["layers"].items():
            stamp = entries[0]["osm_timestamp"] or "n/a"
            parts.append(f"{layer} {stamp}")
        lines.append(f"- {region['id']}: " + ", ".join(parts))
    if manifest["base"]:
        lines += ["", "## Base packs", ""]
        lines += [f"- base pack {p['id']} (z0–{p['max_zoom']}): {', '.join(p['regions'])}" for p in manifest["base"]]
    lines += ["", f"{carried} entries carried from earlier releases.", "",
              "Attribution: " + "; ".join(a["text"] for a in manifest["attribution"]) + ".", ""]
    return "\n".join(lines)
```

CLI:

```python
from maqs.release import ReleaseError, carried_count, local_assets, release_notes


@main.command("release-check")
@click.option("--dist", type=click.Path(path_type=Path, exists=True, file_okay=False), required=True)
@click.option("--manifest", "manifest_file", type=click.Path(path_type=Path, exists=True, dir_okay=False), required=True)
@click.option("--notes", type=click.Path(path_type=Path), default=None, help="Write the release notes here.")
def release_check(dist: Path, manifest_file: Path, notes: Path | None) -> None:
    """Assert every asset the manifest names for its release exists in dist with the right bytes and sha256."""
    doc = json.loads(manifest_file.read_text(encoding="utf-8"))
    try:
        validate(doc, "manifest")
        assets = local_assets(doc, dist)
    except (SchemaError, ReleaseError) as exc:
        raise click.ClickException(str(exc)) from exc
    for asset in assets:
        click.echo(f"{asset.file} {asset.bytes}")
    click.echo(f"total {len(assets)} assets, {sum(a.bytes for a in assets)} bytes")
    if notes is not None:
        notes.write_text(release_notes(doc, carried_count(doc)), encoding="utf-8")
        click.echo(f"wrote {notes}")
```

- [ ] **Step 4: Run the suite, lint, commit**

Run: `uv run pytest -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

```bash
git add pipeline/src/maqs/release.py pipeline/src/maqs/cli.py pipeline/tests
git commit -m "feat(pipeline): maqs release-check verifies the release assets and writes the notes"
```

---

### Task 4: `build-maps.yml` and the workflow assertions test

**Files:**
- Create: `.github/workflows/build-maps.yml`, `pipeline/tests/test_workflows.py`
- Modify: `pipeline/pyproject.toml` (dev dependency group `[dependency-groups] dev = ["pytest", "pyyaml>=6.0"]` — pyyaml is already a runtime dependency, so no change is needed; confirm and skip)

**Interfaces:**
- Consumes: `maqs check-config`, `maqs regions --json`, `maqs fetch`, `maqs build`, `maqs manifest`, `maqs release-check`, `maqs check-tools`, `pipeline/bootstrap.sh`, the `TOOLS_KEY` from `pipeline.yml`.

- [ ] **Step 1: Write the failing workflow test**

```python
# pipeline/tests/test_workflows.py
"""Shape assertions on the GitHub Actions workflows: pinned actions, least privilege, no cancellation."""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", ["pipeline.yml", "build-maps.yml"])
def test_every_action_is_pinned_to_a_major_tag(name):
    doc = load(name)
    uses = [s["uses"] for job in doc["jobs"].values() for s in job["steps"] if "uses" in s]
    assert uses, name
    for ref in uses:
        assert re.fullmatch(r"[\w.-]+/[\w.-]+@v\d+", ref), ref


def test_build_maps_writes_only_from_the_release_job():
    doc = load("build-maps.yml")
    assert doc["permissions"] == {"contents": "read"}
    for name, job in doc["jobs"].items():
        perms = job.get("permissions", {})
        if name == "release":
            assert perms == {"contents": "write"}
        else:
            assert "write" not in perms.values()


def test_build_maps_never_cancels_and_publishes_only_full_runs():
    doc = load("build-maps.yml")
    assert doc["concurrency"] == {"group": "build-maps", "cancel-in-progress": False}
    on_key = True if True in doc else "on"  # PyYAML reads the bare key `on` as the boolean True
    assert "schedule" in doc[on_key] and "workflow_dispatch" in doc[on_key]
    release = doc["jobs"]["release"]
    assert "needs.prepare.outputs.full == 'true'" in release["if"]
    assert set(release["needs"]) == {"prepare", "build"}
    run_text = "\n".join(s.get("run", "") for s in release["steps"])
    assert "manifest.json --clobber" in run_text and "--latest" in run_text
    assert run_text.index("release-check") < run_text.index("gh release upload")
    assert run_text.rindex("dist/manifest.json --clobber") > run_text.index("gh release upload")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_workflows.py -q`
Expected: FAIL with `FileNotFoundError` for `build-maps.yml` (the `pipeline.yml` case passes).

- [ ] **Step 3: Write the workflow**

```yaml
# .github/workflows/build-maps.yml
name: build-maps

on:
  schedule:
    - cron: "0 3 1 * *"   # 03:00 UTC on the 1st of each month
  workflow_dispatch:
    inputs:
      region:
        description: "One region id (or 'base'); empty builds every region and publishes"
        default: ""
        type: string
      layers:
        description: "Comma-separated layers; empty builds the default layers"
        default: ""
        type: string

permissions:
  contents: read

concurrency:
  group: build-maps
  cancel-in-progress: false   # a publishing run always finishes

env:
  # Must match the pins in pipeline/bootstrap.sh and maqs.tools.PINS (same as pipeline.yml).
  TOOLS_KEY: versatiles-5.0.0-pmtiles-1.31.2-osmium-1.19.1-tippecanoe-2.79.0

jobs:
  prepare:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    outputs:
      targets: ${{ steps.plan.outputs.targets }}
      release: ${{ steps.plan.outputs.release }}
      full: ${{ steps.plan.outputs.full }}
      layers: ${{ steps.plan.outputs.layers }}
      md5: ${{ steps.geofabrik.outputs.md5 }}
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@v7
        with: { enable-cache: true }
      - run: uv sync --frozen
        working-directory: pipeline
      - run: uv run maqs check-config
        working-directory: pipeline
      - name: Plan the run
        id: plan
        shell: bash
        working-directory: pipeline
        env:
          REGION: ${{ inputs.region }}
          LAYERS: ${{ inputs.layers }}
        run: |
          set -euo pipefail
          json=$(uv run maqs regions --json)
          if [[ -z "$REGION" && -z "$LAYERS" ]]; then full=true; else full=false; fi
          if [[ -z "$REGION" ]]; then
            targets=$(jq -c '[.regions[] | select(.fixture|not) | .id]' <<<"$json")
          elif [[ "$REGION" == "base" ]]; then
            targets='["base"]'
          else
            known=$(jq -r '.regions[].id' <<<"$json")
            grep -qx -- "$REGION" <<<"$known" || { echo "unknown region '$REGION'; valid: $(tr '\n' ' ' <<<"$known") base" >&2; exit 1; }
            targets=$(jq -c --arg r "$REGION" '[$r]' <<<"$json")
          fi
          if [[ "$full" == true ]]; then targets=$(jq -c '. + ["base"]' <<<"$targets"); fi
          echo "targets=$targets" >> "$GITHUB_OUTPUT"
          echo "release=data-$(date -u +%Y-%m)" >> "$GITHUB_OUTPUT"
          echo "full=$full" >> "$GITHUB_OUTPUT"
          echo "layers=$LAYERS" >> "$GITHUB_OUTPUT"
          echo "targets $targets, release data-$(date -u +%Y-%m), full $full"
      - name: Disk space
        shell: bash
        run: |
          avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
          echo "free: ${avail} GB (a full run needs about 3 GB)"
          [[ "$avail" -ge 6 ]] || { echo "less than 6 GB free" >&2; exit 1; }
      - name: Geofabrik extract checksum
        id: geofabrik
        shell: bash
        run: |
          md5=$(curl -fsSL -A "maqs-pipeline-ci (+https://github.com/lucavallin/maqs)" \
            https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf.md5 | cut -d' ' -f1)
          [[ "$md5" =~ ^[0-9a-f]{32}$ ]] || { echo "bad md5: '$md5'" >&2; exit 1; }
          echo "md5=$md5" >> "$GITHUB_OUTPUT"
      - name: Cache the Geofabrik extract
        uses: actions/cache@v6
        with:
          path: .cache/geofabrik
          key: geofabrik-europe-italy-nord-est-${{ steps.geofabrik.outputs.md5 }}
      - name: Download the extract once
        run: uv run maqs fetch --extract europe/italy/nord-est --cache "$GITHUB_WORKSPACE/.cache"
        working-directory: pipeline

  build:
    needs: prepare
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    strategy:
      fail-fast: false
      matrix:
        target: ${{ fromJSON(needs.prepare.outputs.targets) }}
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@v7
        with: { enable-cache: true }
      - name: Cache tool binaries
        id: tools-cache
        uses: actions/cache@v6
        with:
          path: |
            /usr/local/bin/versatiles
            /usr/local/bin/pmtiles
            /usr/local/bin/osmium
            /usr/local/bin/tippecanoe
            /usr/local/bin/tile-join
          key: tools-${{ runner.os }}-${{ runner.arch }}-${{ env.TOOLS_KEY }}
      - name: Bootstrap tools
        if: steps.tools-cache.outputs.cache-hit != 'true'
        run: pipeline/bootstrap.sh
      - name: Runtime libraries for cached binaries
        if: steps.tools-cache.outputs.cache-hit == 'true'
        run: sudo apt-get update -q && sudo apt-get install -y -q libboost-program-options1.83.0 liblz4-1 libexpat1 libbz2-1.0 libsqlite3-0
      - run: pipeline/bootstrap.sh --check
      - run: uv sync --frozen
        working-directory: pipeline
      - run: uv run maqs check-tools
        working-directory: pipeline
      - name: Restore the Geofabrik extract
        uses: actions/cache@v6
        with:
          path: .cache/geofabrik
          key: geofabrik-europe-italy-nord-est-${{ needs.prepare.outputs.md5 }}
      - name: Build ${{ matrix.target }}
        shell: bash
        working-directory: pipeline
        env:
          LAYERS: ${{ needs.prepare.outputs.layers }}
        run: |
          set -euo pipefail
          args=(--region "${{ matrix.target }}" --dist "$GITHUB_WORKSPACE/dist" --cache "$GITHUB_WORKSPACE/.cache")
          if [[ -n "$LAYERS" ]]; then args+=(--layers "$LAYERS"); fi
          uv run maqs build "${args[@]}"
      - run: cat "dist/${{ matrix.target }}/build-report.json"
      - uses: actions/upload-artifact@v7
        with:
          name: dist-${{ matrix.target }}
          path: dist/${{ matrix.target }}
          retention-days: 7
          if-no-files-found: error

  release:
    needs: [prepare, build]
    if: needs.prepare.outputs.full == 'true'
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    permissions:
      contents: write
    env:
      GH_TOKEN: ${{ github.token }}
      RELEASE: ${{ needs.prepare.outputs.release }}
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@v7
        with: { enable-cache: true }
      - run: uv sync --frozen
        working-directory: pipeline
      - uses: actions/download-artifact@v7
        with:
          pattern: dist-*
          path: artifacts
      - name: Lay out dist/
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p dist
          for d in artifacts/dist-*; do mv "$d" "dist/${d#artifacts/dist-}"; done
          ls dist
      - name: Fetch the latest published manifest
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p previous
          if gh release download --pattern manifest.json --dir previous 2>/dev/null && [[ -s previous/manifest.json ]]; then
            echo "previous manifest: $(jq -r .release previous/manifest.json)"
          else
            echo "no published manifest yet; first release"
            rm -f previous/manifest.json
          fi
      - name: Assemble the manifest
        shell: bash
        working-directory: pipeline
        run: |
          set -euo pipefail
          args=(--release "$RELEASE" --dist "$GITHUB_WORKSPACE/dist")
          if [[ -s "$GITHUB_WORKSPACE/previous/manifest.json" ]]; then args+=(--previous "$GITHUB_WORKSPACE/previous/manifest.json"); fi
          uv run maqs manifest "${args[@]}"
          uv run maqs check-config --manifest "$GITHUB_WORKSPACE/dist/manifest.json"
      - name: Check the assets and write the notes
        run: uv run maqs release-check --dist "$GITHUB_WORKSPACE/dist" --manifest "$GITHUB_WORKSPACE/dist/manifest.json" --notes "$GITHUB_WORKSPACE/notes.md" | tee "$GITHUB_WORKSPACE/assets.txt"
        working-directory: pipeline
      - name: Create the release if the tag is new
        shell: bash
        run: |
          set -euo pipefail
          if gh release view "$RELEASE" >/dev/null 2>&1; then
            echo "release $RELEASE exists; assets will be replaced"
          else
            gh release create "$RELEASE" --target "$GITHUB_SHA" --title "Map data ${RELEASE#data-}" --notes-file notes.md --latest=false
          fi
      - name: Upload the assets, then the manifest
        shell: bash
        run: |
          set -euo pipefail
          files=()
          while read -r name _; do
            [[ "$name" == total ]] && break
            files+=("$(find dist -name "$name" -type f | head -1)")
          done < assets.txt
          gh release upload "$RELEASE" "${files[@]}" --clobber
          gh release upload "$RELEASE" dist/manifest.json --clobber
          gh release edit "$RELEASE" --latest --notes-file notes.md
      - name: Summary
        shell: bash
        run: |
          { echo "## $RELEASE"; echo; echo '```'; cat assets.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
```

Notes for the implementer: `gh release create --latest=false` keeps an in-progress release from being latest before its assets exist; the final `edit --latest` flips it. `gh release upload` accepts many files in one call. The `find` in the upload step resolves each asset name to its `dist/<label>/` path; names are unique across labels because they start with the label.

- [ ] **Step 4: Validate and run the tests**

Run from the repo root: `uv run --with pyyaml --directory pipeline python -I -c "import yaml; yaml.safe_load(open('../.github/workflows/build-maps.yml')); print('yaml ok')"` (or the system Python if it has PyYAML); then from `pipeline/`: `uv run pytest tests/test_workflows.py -q && uv run pytest -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-maps.yml pipeline/tests/test_workflows.py
git commit -m "ci: build-maps workflow — monthly release build with a matrix per region and a publish-only-when-full release job"
```

---

### Task 5: Push and the live subset run

**Files:** none (verification only)

- [ ] **Step 1: Push**

```bash
git push origin main
gh run watch --exit-status   # pipeline.yml must stay green
```

- [ ] **Step 2: Dispatch a subset run**

```bash
gh workflow run build-maps.yml --ref main -f region=test
sleep 20; gh run list --workflow build-maps.yml --limit 1
gh run watch <id> --exit-status
```

Expected: `prepare` green (targets `["test"]`, full false), one `build` job green with artifact `dist-test`, `release` skipped. Record: durations per job, whether the Geofabrik cache hit (`prepare` miss then save; `build` hit), artifact size, `df` output. If `prepare` or `build` fails on the runner, fix with a focused commit and push again; at most 3 iterations, then stop and report.

- [ ] **Step 3: Record**

Write the measurements into the report file for Task 6's ADR.

---

### Task 6: Documentation and ADR 0013

**Files:**
- Modify: `docs/decisions.md`, `docs/architecture.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: ADR 0013 — Release workflow** (format as 0012; date 2026-10-16; status accepted (owner decision 2026-10-16)): context (brief Phase 3; the manifest contract of ADR 0012; the production endpoint); decision (three jobs, matrix per region, md5-keyed extract cache warmed by `maqs fetch`, `release` only on full runs, `maqs release-check` before any upload, assets before `manifest.json`, `--clobber`, explicit `--latest`, `--target $GITHUB_SHA`, disk check instead of a free-space action with the measured free/needed figures from Task 5, retention 7 days); verified facts with the date 2026-10-16: `gh release upload --clobber` deletes and re-uploads (originals lost if the upload fails), `gh release edit --latest`, `gh release download` without a tag reads the latest release, `gh release create` tags the default branch head unless `--target`, GitHub's "latest" = most recent non-draft non-prerelease by the tagged commit's date; rejected: one sequential job, publishing subsets, a third-party free-disk-space action; consequences: same-month re-run semantics, the accepted mid-upload failure mode (clients verify SHA-256 and re-fetch the manifest), the first-release procedure, Phase 4 may assume the manifest is uploaded last; `CONTRADICTS BRIEF` (minor): `swift.yml` deferred to Phase 4; Task 5's measurements.
- [ ] **Step 2: `docs/architecture.md`** — "Data releases" section: the three jobs, artifact and cache layout, what a subset dispatch does, re-run semantics, the client contract; update "CI".
- [ ] **Step 3: `README.md`** — "Data releases": where (`releases/latest/download/manifest.json`), when (1st of the month 03:00 UTC), how to re-run (`gh workflow run build-maps.yml`), what a `region:` dispatch does.
- [ ] **Step 4: `CLAUDE.md` §1** — Commands (`maqs regions --json`, `maqs fetch`, `maqs release-check`, `gh workflow run build-maps.yml [-f region=…]`), Environments and repository map (`build-maps.yml` real), traps: "`gh release upload --clobber` deletes before it uploads"; "`gh release create` tags the default branch head — pass `--target $GITHUB_SHA`"; "subset dispatches never publish; only a full run assembles the manifest". Update "Where we are" to Phase 3 done once Task 7 is.
- [ ] **Step 5: Humanizer pass over the README and ADR text; commit; push**

```bash
git add docs/decisions.md docs/architecture.md README.md CLAUDE.md
git commit -m "docs: release workflow, ADR 0013, data releases in the README and architecture"
git push origin main
```

---

### Task 7: First publish (owner go required)

**Files:** `docs/decisions.md` (ADR 0013 measurements), `CLAUDE.md` ("Where we are")

- [ ] **Step 1: STOP and ask the owner.** This step publishes `data-2026-10` to the production endpoint. Proceed only on an explicit go in the conversation.
- [ ] **Step 2: Dispatch a full run**

```bash
gh workflow run build-maps.yml --ref main
sleep 20; gh run list --workflow build-maps.yml --limit 1
gh run watch <id> --exit-status
```

Expected: `prepare`, five `build` jobs (four regions + base), `release` green. Then verify from outside:

```bash
curl -sIL https://github.com/lucavallin/maqs/releases/latest/download/manifest.json | grep -i '^HTTP\|^location' | head
curl -sL https://github.com/lucavallin/maqs/releases/latest/download/manifest.json -o /tmp/m.json && (cd pipeline && uv run maqs check-config --manifest /tmp/m.json)
gh release view data-2026-10 --json tagName,isLatest,assets --jq '.tagName, .isLatest, (.assets | length), ([.assets[].size] | add)'
```

Expected: 200 after redirects; `ok: manifest.json`; `data-2026-10 true 20 <bytes>` (4 regions × 7 files + base + manifest = 30 … count exactly: 4×7 = 28 + 1 base + 1 manifest = 30 assets).

- [ ] **Step 3: Re-run the same month** (`gh workflow run build-maps.yml --ref main`) and confirm the release still has 30 assets, `isLatest` true, the manifest's `created_at` moved, `release-check`'s log shows `carried 0 entries`.
- [ ] **Step 4: Record** the run ids, durations, asset total, the carried count and the re-run result in ADR 0013; set CLAUDE.md "Where we are" to Phase 3 done; commit; push.

```bash
git add docs/decisions.md CLAUDE.md
git commit -m "docs: first data release measured in ADR 0013; Phase 3 done"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** triggers/inputs/concurrency, prepare, build, release, re-run and failure semantics (Task 4); CLI additions (Tasks 1–3); docs (Task 6); tests (Tasks 1–4); live verification (Tasks 5, 7); `swift.yml` deferred (ADR 0013); first publish gated (Task 7 Step 1).
- **Type consistency:** `fetch_extract(cache, extract)` (Task 2) used by the CLI and the workflow (`maqs fetch`); `local_assets`, `release_notes`, `carried_count`, `ReleaseError`, `Asset` (Task 3) used by `release-check`; `url_tag` from `maqs.manifest` (exists); workflow step order asserted by `test_workflows.py` (Task 4).
- **Review Focus coverage:** (1) `test_missing_file_fails`, `test_release_check_fails_on_a_missing_asset`; (2) `test_carried_entries_are_not_required_locally`; (3) workflow shell `|| true`-style guard reviewed in Task 4, live in Task 7; (4) `test_regions_json_lists_regions_base_packs_and_extracts` plus the jq guard; (5) Task 4 `full` logic, Task 5 live.
- **Asset count in Task 7: 4 regions × 7 files (basemap, terrain, trails ×2, places ×2, curvature) = 28, plus `base-triveneto-basemap.v1.pmtiles` and `manifest.json` = 30.
