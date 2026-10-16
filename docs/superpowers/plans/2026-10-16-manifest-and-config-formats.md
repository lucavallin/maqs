# Manifest and Config Formats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the pipeline versioned, schema-validated `manifest.json` and `config/sources.json` formats with a written compatibility rule, the `maqs manifest` and `maqs check-config` commands that produce and check them, and versioned output file names, so Phase 3's workflow only calls commands and Phase 4's Swift reader has a fixed contract.

**Architecture:** A small `layers.py` owns the layer → schema-version map and the output-name rule; every step names its outputs through it and `run_step` stamps `layer`, `layer_schema_version` and `data_date` on each validated output. `schemas.py` wraps `jsonschema` over the two Draft 2020-12 schemas in `config/schemas/`. `manifest.py` turns the per-region build reports into the manifest (with carry-over of lower schema versions from a previous manifest) and validates it before writing. Two click commands expose this; CI runs both on the test build.

**Tech Stack:** Python 3.12, `uv`, `click`, `jsonschema>=4.23` (new, MIT), stdlib `json`/`hashlib`/`datetime`; the existing `maqs` package (`config`, `report`, `validate`, `steps`).

**Spec:** `docs/superpowers/specs/2026-10-16-manifest-and-config-formats-design.md`

## Global Constraints

- Output names: `<label>-<layer>.v<N>.<ext>` for every build output (`veneto-trails.v1.sqlite`, `veneto-basemap.v1.pmtiles`, `base-triveneto-basemap.v1.pmtiles`); `N` comes from one map, `LAYER_SCHEMA_VERSION`, with `basemap`, `terrain`, `terrain-hd` → 1 and the SQLite layers from `sqlite_out.SCHEMA_VERSION` (all 1).
- `manifest.json`: `manifest_version` 1; `created_at` ISO 8601 UTC with `Z`; `release` matches `^data-\d{4}-\d{2}$`; `shortbread_version` `"1.0"`; every `url` is `https://github.com/lucavallin/maqs/releases/download/<release>/<file>` (tag-pinned, never `latest`); `sha256` 64 lowercase hex; `bytes` 1 … 2040109465; layer lists ordered by `layer_schema_version` descending, SQLite before its overlay (`role: "overlay"`); fixture regions excluded unless `--include-fixtures`; `base` lists every configured base pack with `basemap` only; `additionalProperties: false` everywhere.
- Compatibility rule (data-format.md): client takes the first entry per layer whose version it supports; none → layer not available; unknown `manifest_version` → typed error; unknown fields ignored; a schema bump ships both versions for one release (`--previous` carry-over copies lower-version entries verbatim, never equal or higher).
- `config/sources.json`: `sources_version` 1; `layers.basemap` and `layers.terrain` only, ordered non-empty lists, one VersaTiles entry each; `tiles` HTTPS with `{z}`,`{x}`,`{y}`; `tilejson` HTTPS; `schema` `shortbread-1.0` / `terrarium`; `format` `mvt`|`webp`|`png`; `tile_size` 256|512; `0 ≤ min_zoom ≤ max_zoom ≤ 22`; attribution strings verbatim from `DATA_LICENSE.md`. Live-verified on 2026-10-16: `https://tiles.versatiles.org/tiles/osm/tiles.json` (TileJSON 3.0.0, `tiles` `/tiles/osm/{z}/{x}/{y}`, zoom 0–14, `tile_schema` `shortbread@1.0`, `tile_format` `application/vnd.mapbox-vector-tile`, attribution OSM + CC BY 4.0 ESA WorldCover 2021, `planetiler:osm:osmosisreplicationtime` 2026-06-07T23:59:58Z) and `https://tiles.versatiles.org/tiles/elevation/tiles.json` (zoom 0–12, `tile_schema` `dem/terrarium`, `tile_format` `image/webp`, attribution `© Mapterhorn`).
- Attribution display strings (verbatim, `DATA_LICENSE.md`): `© OpenStreetMap contributors` (ODbL 1.0, https://www.openstreetmap.org/copyright), `CC BY 4.0 ESA WorldCover 2021` (CC BY 4.0, https://esa-worldcover.org/en/data-access), `© Mapterhorn` (multiple open licences, https://mapterhorn.com/attribution).
- Build report stays `report_version` 1 (additive): outputs gain `layer`, `layer_schema_version`, `data_date` (`YYYY-MM-DD` UTC build date); `source_data_date` stays and becomes `osm_timestamp` in the manifest.
- `maqs manifest` exits 1 when a non-fixture region, a standard layer, a base pack or a report is missing, when a report's `validation.ok` is false, or when the result fails the schema; `maqs check-config` exits 2 on a violation naming the JSON path. Nothing here touches the network.
- Every CLI call goes through `maqs.tools.run`; unit tests never touch the network (autouse guard); fixtures are small and synthetic.
- Ruff (line-length 100; select E,F,I,B,UP,SIM,PTH) clean after `ruff format`, no suppressions; type hints; pathlib. Conventional commits; every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; direct to `main`; never force-push; nothing generated committed (`dist/`, `.cache/`, `*.sqlite`, `*.pmtiles`, `*.pbf`).
- `jsonschema` is the only new dependency (approved 2026-10-16); `uv lock` regenerates the lockfile, never hand-edited.

## Review Focus

1. **A region whose build report says `validation.ok: false`** (a failed step). Expected: `maqs manifest` refuses with the region and the failure text; no manifest written. Test in Task 5.
2. **A previous manifest naming a region or layer that no longer exists in `regions.yaml`**, or an entry with the same version as the current build. Expected: carry-over ignores unknown regions and never produces two entries with one version; the result still validates. Test in Task 5.
3. **A `sources.json` or manifest edited by hand with an `http://` URL, a `releases/latest/download/` URL, or an unknown field.** Expected: `check-config` exits 2 and prints the JSON path (`layers/basemap/0/tiles`). Test in Tasks 3 and 4.
4. **A base pack configured but not built** (`dist/base/` missing or the pack's output absent). Expected: `maqs manifest` fails naming `base-<pack>`; `--include-fixtures` does not change that. Test in Task 5.
5. **An existing `dist/` from before this plan** (files named `veneto-trails.sqlite`). Expected: `maqs build` does not reuse them (new names → rebuilt) and `maqs manifest` fails on the missing new names rather than picking up the old files. Test in Task 1 (outputs) and Task 5 (manifest reads only report entries).

---

### Task 1: `layers.py`, versioned output names, report additions

**Files:**
- Create: `pipeline/src/maqs/layers.py`, `pipeline/tests/test_layers.py`
- Modify: `pipeline/src/maqs/steps/tiles.py`, `pipeline/src/maqs/steps/terrain_hd.py`, `pipeline/src/maqs/trails/step.py`, `pipeline/src/maqs/places/step.py`, `pipeline/src/maqs/curvature/step.py`, `pipeline/src/maqs/steps/base.py`, `pipeline/src/maqs/validate.py` (`OutputInfo`), `pipeline/src/maqs/cli.py` (fixture-size warning), `pipeline/tests/test_steps_tiles.py`, `pipeline/tests/test_steps_terrain_hd.py`, `pipeline/tests/test_steps_trails.py`, `pipeline/tests/test_steps_places.py`, `pipeline/tests/test_steps_curvature.py`, `pipeline/tests/test_steps_base.py`, `pipeline/tests/test_report.py`, `pipeline/tests/test_cli.py`, `pipeline/tests/test_integration_network.py`

**Interfaces:**
- Consumes: `sqlite_out.SCHEMA_VERSION` (`{"trails": 1, "places": 1, "curvature": 1}`), `OutputInfo` (frozen dataclass), `run_step`, `Step` protocol.
- Produces:
  - `layers.py`: `STANDARD_LAYERS: tuple[str, ...] = ("basemap", "terrain", "trails", "places", "curvature")`; `TILE_SCHEMA_VERSION = {"basemap": 1, "terrain": 1, "terrain-hd": 1}`; `LAYER_SCHEMA_VERSION: dict[str, int]` (tile map merged with `SCHEMA_VERSION`); `output_name(label: str, layer: str, ext: str) -> str` → `f"{label}-{layer}.v{LAYER_SCHEMA_VERSION[layer]}.{ext}"` (raises `KeyError` for an unknown layer).
  - `Step` protocol gains `layer: str` (the layer a step produces; `BasePackStep.layer = "basemap"`, `TerrainHDStep.layer = "terrain-hd"`).
  - `OutputInfo` gains `layer: str | None = None`, `layer_schema_version: int | None = None`, `data_date: str | None = None` (after `rows`); `run_step` fills them via `dataclasses.replace` after validation, `data_date = datetime.now(UTC).strftime("%Y-%m-%d")` (injectable through a module-level `_today()` helper for tests).
  - Report output dicts carry the three new keys (always present; `None` is written as JSON null only for `data_date` when a step failed before validation — in practice every validated output has all three).

- [ ] **Step 1: Write the failing tests for `layers.py`**

```python
# pipeline/tests/test_layers.py
import pytest

from maqs.layers import LAYER_SCHEMA_VERSION, STANDARD_LAYERS, output_name


def test_every_standard_layer_has_schema_version_one_today():
    assert STANDARD_LAYERS == ("basemap", "terrain", "trails", "places", "curvature")
    assert {LAYER_SCHEMA_VERSION[layer] for layer in STANDARD_LAYERS} == {1}
    assert LAYER_SCHEMA_VERSION["terrain-hd"] == 1


def test_output_name_carries_the_schema_version():
    assert output_name("veneto", "trails", "sqlite") == "veneto-trails.v1.sqlite"
    assert output_name("base-triveneto", "basemap", "pmtiles") == "base-triveneto-basemap.v1.pmtiles"


def test_output_name_rejects_an_unknown_layer():
    with pytest.raises(KeyError):
        output_name("veneto", "roads", "sqlite")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `pipeline/`): `uv run pytest tests/test_layers.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.layers'`.

- [ ] **Step 3: Create `layers.py`**

```python
# pipeline/src/maqs/layers.py
"""Layer names, their schema versions and the versioned output file names."""

from __future__ import annotations

from maqs.sqlite_out import SCHEMA_VERSION

STANDARD_LAYERS: tuple[str, ...] = ("basemap", "terrain", "trails", "places", "curvature")

# Tile layers: 1 = Shortbread 1.0 gzip MVT z0-14 (basemap), terrarium WebP 512 px z0-12 (terrain,
# terrain-hd). A change in encoding, zoom range or schema bumps the number (docs/data-format.md).
TILE_SCHEMA_VERSION: dict[str, int] = {"basemap": 1, "terrain": 1, "terrain-hd": 1}

LAYER_SCHEMA_VERSION: dict[str, int] = {**TILE_SCHEMA_VERSION, **SCHEMA_VERSION}


def output_name(label: str, layer: str, ext: str) -> str:
    """`<label>-<layer>.v<N>.<ext>`: two schema versions of one layer can share a release."""
    return f"{label}-{layer}.v{LAYER_SCHEMA_VERSION[layer]}.{ext}"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_layers.py -q`
Expected: 3 passed.

- [ ] **Step 5: Rename every step's outputs through `output_name`**

In `pipeline/src/maqs/steps/tiles.py`:

```python
from maqs.layers import output_name

class _VersatilesStep:
    name = "tiles"
    suffix = ""

    @property
    def layer(self) -> str:
        return self.suffix

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / output_name(ctx.label, self.suffix, "pmtiles")]
```

and in `BasePackStep.outputs`: `return [ctx.out_dir / output_name(self.name, "basemap", "pmtiles")]` (keep `suffix = "basemap"`; `layer` resolves to `"basemap"` through the property).

In `pipeline/src/maqs/steps/terrain_hd.py`: add class attribute `layer = "terrain-hd"`; `outputs` returns `[ctx.out_dir / output_name(ctx.label, "terrain-hd", "pmtiles")]`.

In `pipeline/src/maqs/trails/step.py`: `layer = "trails"`; outputs `[ctx.out_dir / output_name(ctx.label, "trails", "sqlite"), ctx.out_dir / output_name(ctx.label, "trails", "pmtiles")]`; the terrain archive lookup becomes `ctx.out_dir / output_name(ctx.label, "terrain", "pmtiles")`.

In `pipeline/src/maqs/places/step.py`: `layer = "places"`; outputs via `output_name(ctx.label, "places", "sqlite")` / `"pmtiles"`.

In `pipeline/src/maqs/curvature/step.py`: `layer = "curvature"`; output `output_name(ctx.label, "curvature", "sqlite")`.

In `pipeline/src/maqs/steps/base.py`: add `layer: str` to the `Step` protocol under `name`.

In `pipeline/src/maqs/cli.py`, the fixture-size warning filter: replace `o.file.endswith(("-basemap.pmtiles", "-terrain.pmtiles"))` with `o.layer in ("basemap", "terrain")` (uses the new field from Step 7; do this edit after Step 7, or in the same commit).

- [ ] **Step 6: Update every test that names an output and run the step tests**

`grep -rn '\-\(basemap\|terrain\|terrain-hd\|trails\|places\|curvature\)\.\(pmtiles\|sqlite\)' pipeline/tests` lists every literal. Replace each with the `.v1.` form (e.g. `test-trails.v1.sqlite`, `test-basemap.v1.pmtiles`, `base-triveneto-basemap.v1.pmtiles`), including `tests/test_integration_network.py`'s file-existence list. Where a test builds a terrain archive for the trails step, its path must be `output_name("test", "terrain", "pmtiles")`. Do not change any assertion other than the file name (state this in the commit body).

Run: `uv run pytest tests/test_steps_tiles.py tests/test_steps_terrain_hd.py tests/test_steps_trails.py tests/test_steps_places.py tests/test_steps_curvature.py tests/test_cli.py -q`
Expected: all pass.

- [ ] **Step 7: Write the failing test for the report additions**

Append to `pipeline/tests/test_steps_base.py` (reuse the module's existing `FakeStep` and `ctx` fixture; `FakeStep` gains `layer = "basemap"`):

```python
def test_validated_outputs_carry_layer_version_and_build_date(ctx, monkeypatch):
    from maqs.steps import base

    monkeypatch.setattr(base, "_today", lambda: "2026-10-16")
    result = run_step(FakeStep(), ctx)
    assert result.status == "built"
    info = result.outputs[0]
    assert (info.layer, info.layer_schema_version, info.data_date) == ("basemap", 1, "2026-10-16")
```

And in `pipeline/tests/test_report.py`, extend the existing report-shape test so an output dict contains `"layer"`, `"layer_schema_version"` and `"data_date"` keys (construct the `OutputInfo` with `layer="trails", layer_schema_version=1, data_date="2026-10-16"` and assert the JSON carries them).

- [ ] **Step 8: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_base.py tests/test_report.py -q`
Expected: FAIL with `TypeError: OutputInfo.__init__() got an unexpected keyword argument 'layer'` / `AttributeError: module 'maqs.steps.base' has no attribute '_today'`.

- [ ] **Step 9: Add the fields and stamp them in `run_step`**

In `pipeline/src/maqs/validate.py`, `OutputInfo` gains after `rows`:

```python
    layer: str | None = None
    layer_schema_version: int | None = None
    data_date: str | None = None
```

In `pipeline/src/maqs/steps/base.py`:

```python
from dataclasses import replace
from datetime import UTC, datetime

from maqs.layers import LAYER_SCHEMA_VERSION


def _today() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%d")
```

and in `run_step`, where each output is validated:

```python
            info = validate_output(path, step.expectation(ctx, path))
            infos.append(
                replace(
                    info,
                    layer=step.layer,
                    layer_schema_version=LAYER_SCHEMA_VERSION[step.layer],
                    data_date=_today(),
                )
            )
```

`report.py` needs no change: `asdict` already serialises the new fields (`metadata` is still popped; `rows` still popped when None).

- [ ] **Step 10: Run the whole suite and lint**

Run: `uv run ruff format . && uv run ruff check . && uv run pytest -q`
Expected: all pass (count rises by 4), ruff clean.

- [ ] **Step 11: Commit**

```bash
git add pipeline/src/maqs/layers.py pipeline/src/maqs/steps pipeline/src/maqs/trails/step.py pipeline/src/maqs/places/step.py pipeline/src/maqs/curvature/step.py pipeline/src/maqs/validate.py pipeline/src/maqs/cli.py pipeline/tests
git commit -m "feat(pipeline): versioned output names and per-output layer metadata in the report

Outputs are now <label>-<layer>.v<N>.<ext> so two schema versions of one
layer can share a release. Every validated output records layer,
layer_schema_version and data_date (report_version stays 1, additive).
Existing tests only changed the file names they assert."
```

---

### Task 2: `jsonschema` dependency, the two schemas, `schemas.py`

**Files:**
- Modify: `pipeline/pyproject.toml` (add `"jsonschema>=4.23"`), `pipeline/uv.lock` (via `uv lock`)
- Create: `config/schemas/manifest.schema.json`, `config/schemas/sources.schema.json`, `pipeline/src/maqs/schemas.py`, `pipeline/tests/test_schemas.py`

**Interfaces:**
- Produces: `schemas.py`: `SCHEMAS_DIR = Path(__file__).resolve().parents[3] / "config" / "schemas"` (repo root `config/schemas`); `class SchemaError(ValueError)` with attributes `path: str` (JSON pointer-ish, `"/layers/basemap/0/tiles"`; `"/"` for the root) and `message: str`; `load_schema(name: str) -> dict` (`name` ∈ `"manifest"`, `"sources"`); `validate(instance: object, name: str) -> None` raising `SchemaError` on the first error found (sorted by path for determinism); `SIZE_CAP_BYTES = 2_040_109_465`.
- The schemas are data consumed by Task 4 (`check-config`) and Task 5 (`manifest`).

- [ ] **Step 1: Add the dependency**

Edit `pipeline/pyproject.toml`: `dependencies = ["click>=8.1", "pyyaml>=6.0", "osmium>=4.3", "pillow>=12.0", "jsonschema>=4.23"]`. Run `uv lock` from `pipeline/` and `uv sync --frozen`. Record the resolved version in the report (expected 4.2x).

- [ ] **Step 2: Write the failing schema tests**

```python
# pipeline/tests/test_schemas.py
import copy
import json
from pathlib import Path

import pytest

from maqs.schemas import SCHEMAS_DIR, SchemaError, load_schema, validate

ROOT = Path(__file__).resolve().parents[2]

ENTRY = {
    "layer_schema_version": 1,
    "file": "veneto-trails.v1.sqlite",
    "url": "https://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-trails.v1.sqlite",
    "bytes": 1234,
    "sha256": "a" * 64,
    "data_date": "2026-11-01",
    "osm_timestamp": "2026-10-31T20:21:00Z",
}
OVERLAY = {**ENTRY, "file": "veneto-trails.v1.pmtiles", "role": "overlay",
           "url": ENTRY["url"].replace(".sqlite", ".pmtiles")}


def tile_entry(layer: str, ts: str | None = "2026-06-07T23:59:58Z") -> dict:
    name = f"veneto-{layer}.v1.pmtiles"
    return {**ENTRY, "file": name, "osm_timestamp": ts,
            "url": f"https://github.com/lucavallin/maqs/releases/download/data-2026-11/{name}"}


MANIFEST = {
    "manifest_version": 1,
    "created_at": "2026-11-01T03:12:44Z",
    "release": "data-2026-11",
    "shortbread_version": "1.0",
    "attribution": [
        {"text": "© OpenStreetMap contributors", "licence": "ODbL 1.0",
         "url": "https://www.openstreetmap.org/copyright",
         "layers": ["basemap", "trails", "places", "curvature"]},
    ],
    "regions": [
        {
            "id": "veneto",
            "name": {"it": "Veneto", "en": "Veneto"},
            "bbox": [10.6231, 44.7923, 13.1021, 46.6806],
            "layers": {
                "basemap": [tile_entry("basemap")],
                "terrain": [tile_entry("terrain", None)],
                "trails": [ENTRY, OVERLAY],
                "places": [{**ENTRY, "file": "veneto-places.v1.sqlite",
                            "url": ENTRY["url"].replace("trails", "places")}],
                "curvature": [{**ENTRY, "file": "veneto-curvature.v1.sqlite",
                               "url": ENTRY["url"].replace("trails", "curvature")}],
            },
        }
    ],
    "base": [
        {"id": "triveneto", "regions": ["triveneto"], "max_zoom": 10,
         "layers": {"basemap": [{**tile_entry("basemap"),
                                 "file": "base-triveneto-basemap.v1.pmtiles",
                                 "url": "https://github.com/lucavallin/maqs/releases/download/data-2026-11/base-triveneto-basemap.v1.pmtiles"}]}}
    ],
}

SOURCES = json.loads((ROOT / "config" / "sources.json").read_text()) if (ROOT / "config" / "sources.json").exists() else {
    "sources_version": 1,
    "layers": {
        "basemap": [{"id": "versatiles-osm", "provider": "VersaTiles",
                     "tiles": "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
                     "tilejson": "https://tiles.versatiles.org/tiles/osm/tiles.json",
                     "schema": "shortbread-1.0", "format": "mvt", "min_zoom": 0, "max_zoom": 14,
                     "attribution": ["© OpenStreetMap contributors", "CC BY 4.0 ESA WorldCover 2021"]}],
        "terrain": [{"id": "versatiles-elevation", "provider": "VersaTiles",
                     "tiles": "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}",
                     "tilejson": "https://tiles.versatiles.org/tiles/elevation/tiles.json",
                     "schema": "terrarium", "format": "webp", "tile_size": 512,
                     "min_zoom": 0, "max_zoom": 12, "attribution": ["© Mapterhorn"]}],
    },
}


def test_schema_files_exist_and_are_draft_2020_12():
    for name in ("manifest", "sources"):
        schema = load_schema(name)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert (SCHEMAS_DIR / f"{name}.schema.json").exists()


def test_valid_manifest_and_sources_pass():
    validate(MANIFEST, "manifest")
    validate(SOURCES, "sources")


def broken(doc: dict, path: list, value) -> dict:
    out = copy.deepcopy(doc)
    node = out
    for key in path[:-1]:
        node = node[key]
    if value is ...:
        del node[path[-1]]
    else:
        node[path[-1]] = value
    return out


@pytest.mark.parametrize(
    ("path", "value", "where"),
    [
        (["manifest_version"], 2, "/manifest_version"),
        (["shortbread_version"], "1.1", "/shortbread_version"),
        (["release"], "latest", "/release"),
        (["created_at"], "2026-11-01", "/created_at"),
        (["attribution"], [], "/attribution"),
        (["regions", 0, "name", "en"], ..., "/regions/0/name"),
        (["regions", 0, "id"], "Veneto", "/regions/0/id"),
        (["regions", 0, "bbox"], [1, 2, 3], "/regions/0/bbox"),
        (["regions", 0, "layers", "trails", 0, "sha256"], "xyz", "/regions/0/layers/trails/0/sha256"),
        (["regions", 0, "layers", "trails", 0, "bytes"], 2_040_109_466, "/regions/0/layers/trails/0/bytes"),
        (["regions", 0, "layers", "trails", 0, "bytes"], 0, "/regions/0/layers/trails/0/bytes"),
        (["regions", 0, "layers", "trails", 0, "url"],
         "https://github.com/lucavallin/maqs/releases/latest/download/veneto-trails.v1.sqlite",
         "/regions/0/layers/trails/0/url"),
        (["regions", 0, "layers", "trails", 0, "url"],
         "http://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-trails.v1.sqlite",
         "/regions/0/layers/trails/0/url"),
        (["regions", 0, "layers", "trails", 0, "file"], "veneto-trails.sqlite", "/regions/0/layers/trails/0/file"),
        (["regions", 0, "layers", "trails", 1, "role"], "tiles", "/regions/0/layers/trails/1/role"),
        (["regions", 0, "layers", "roads"], [ENTRY], "/regions/0/layers"),
        (["regions", 0, "extra"], 1, "/regions/0"),
        (["base", 0, "layers", "terrain"], [tile_entry("terrain")], "/base/0/layers"),
        (["regions"], [], "/regions"),
    ],
)
def test_invalid_manifests_name_the_offending_path(path, value, where):
    with pytest.raises(SchemaError) as exc:
        validate(broken(MANIFEST, path, value), "manifest")
    assert exc.value.path == where, exc.value.message


@pytest.mark.parametrize(
    ("path", "value", "where"),
    [
        (["sources_version"], 2, "/sources_version"),
        (["layers", "basemap", 0, "tiles"], "https://tiles.versatiles.org/tiles/osm/{z}/{x}", "/layers/basemap/0/tiles"),
        (["layers", "basemap", 0, "tiles"], "http://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}", "/layers/basemap/0/tiles"),
        (["layers", "basemap", 0, "schema"], "terrarium", "/layers/basemap/0/schema"),
        (["layers", "terrain", 0, "schema"], "shortbread-1.0", "/layers/terrain/0/schema"),
        (["layers", "terrain", 0, "tile_size"], ..., "/layers/terrain/0"),
        (["layers", "terrain", 0, "max_zoom"], 23, "/layers/terrain/0/max_zoom"),
        (["layers", "basemap", 0, "attribution"], [], "/layers/basemap/0/attribution"),
        (["layers", "basemap"], [], "/layers/basemap"),
        (["layers", "hillshade"], [], "/layers"),
        (["layers", "basemap", 0, "extra"], 1, "/layers/basemap/0"),
    ],
)
def test_invalid_sources_name_the_offending_path(path, value, where):
    with pytest.raises(SchemaError) as exc:
        validate(broken(SOURCES, path, value), "sources")
    assert exc.value.path == where, exc.value.message


def test_min_zoom_above_max_zoom_is_rejected():
    doc = broken(SOURCES, ["layers", "basemap", 0, "min_zoom"], 15)
    with pytest.raises(SchemaError) as exc:
        validate(doc, "sources")
    assert exc.value.path.startswith("/layers/basemap/0")
```

(`min_zoom ≤ max_zoom` cannot be expressed as a plain JSON Schema constraint between two sibling values without `if/then` over each possible value; `schemas.py` adds this one check in code after schema validation, for sources and for nothing else. Say so in the module docstring.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_schemas.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.schemas'`.

- [ ] **Step 4: Write the two schemas**

`config/schemas/manifest.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://raw.githubusercontent.com/lucavallin/maqs/main/config/schemas/manifest.schema.json",
  "title": "maqs data-release manifest",
  "type": "object",
  "additionalProperties": false,
  "required": ["manifest_version", "created_at", "release", "shortbread_version", "attribution", "regions", "base"],
  "properties": {
    "manifest_version": { "const": 1 },
    "created_at": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$" },
    "release": { "type": "string", "pattern": "^data-\\d{4}-\\d{2}$" },
    "shortbread_version": { "const": "1.0" },
    "attribution": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/attribution" } },
    "regions": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/region" } },
    "base": { "type": "array", "items": { "$ref": "#/$defs/basePack" } }
  },
  "$defs": {
    "id": { "type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$" },
    "layerName": { "enum": ["basemap", "terrain", "terrain-hd", "trails", "places", "curvature"] },
    "attribution": {
      "type": "object",
      "additionalProperties": false,
      "required": ["text", "licence", "url", "layers"],
      "properties": {
        "text": { "type": "string", "minLength": 1 },
        "licence": { "type": "string", "minLength": 1 },
        "url": { "type": "string", "pattern": "^https://" },
        "layers": { "type": "array", "minItems": 1, "uniqueItems": true, "items": { "$ref": "#/$defs/layerName" } }
      }
    },
    "entry": {
      "type": "object",
      "additionalProperties": false,
      "required": ["layer_schema_version", "file", "url", "bytes", "sha256", "data_date", "osm_timestamp"],
      "properties": {
        "layer_schema_version": { "type": "integer", "minimum": 1 },
        "file": { "type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*-(basemap|terrain|terrain-hd|trails|places|curvature)\\.v[0-9]+\\.(pmtiles|sqlite)$" },
        "url": { "type": "string", "pattern": "^https://github\\.com/lucavallin/maqs/releases/download/data-\\d{4}-\\d{2}/[a-z0-9.-]+\\.(pmtiles|sqlite)$" },
        "bytes": { "type": "integer", "minimum": 1, "maximum": 2040109465 },
        "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "data_date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" },
        "osm_timestamp": { "type": ["string", "null"], "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$" },
        "role": { "const": "overlay" }
      }
    },
    "entries": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/entry" } },
    "regionLayers": {
      "type": "object",
      "additionalProperties": false,
      "required": ["basemap", "terrain", "trails", "places", "curvature"],
      "properties": {
        "basemap": { "$ref": "#/$defs/entries" },
        "terrain": { "$ref": "#/$defs/entries" },
        "terrain-hd": { "$ref": "#/$defs/entries" },
        "trails": { "$ref": "#/$defs/entries" },
        "places": { "$ref": "#/$defs/entries" },
        "curvature": { "$ref": "#/$defs/entries" }
      }
    },
    "region": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "bbox", "layers"],
      "properties": {
        "id": { "$ref": "#/$defs/id" },
        "name": {
          "type": "object",
          "required": ["it", "en"],
          "additionalProperties": { "type": "string", "minLength": 1 },
          "properties": { "it": { "type": "string", "minLength": 1 }, "en": { "type": "string", "minLength": 1 } }
        },
        "bbox": { "type": "array", "minItems": 4, "maxItems": 4, "items": { "type": "number" } },
        "layers": { "$ref": "#/$defs/regionLayers" }
      }
    },
    "basePack": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "regions", "max_zoom", "layers"],
      "properties": {
        "id": { "$ref": "#/$defs/id" },
        "regions": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/id" } },
        "max_zoom": { "type": "integer", "minimum": 0, "maximum": 14 },
        "layers": {
          "type": "object",
          "additionalProperties": false,
          "required": ["basemap"],
          "properties": { "basemap": { "$ref": "#/$defs/entries" } }
        }
      }
    }
  }
}
```

`config/schemas/sources.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://raw.githubusercontent.com/lucavallin/maqs/main/config/schemas/sources.schema.json",
  "title": "maqs online tile sources",
  "type": "object",
  "additionalProperties": false,
  "required": ["sources_version", "layers"],
  "properties": {
    "sources_version": { "const": 1 },
    "layers": {
      "type": "object",
      "additionalProperties": false,
      "required": ["basemap", "terrain"],
      "properties": {
        "basemap": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/basemapSource" } },
        "terrain": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/terrainSource" } }
      }
    }
  },
  "$defs": {
    "common": {
      "type": "object",
      "required": ["id", "provider", "tiles", "tilejson", "schema", "format", "min_zoom", "max_zoom", "attribution"],
      "properties": {
        "id": { "type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$" },
        "provider": { "type": "string", "minLength": 1 },
        "tiles": { "type": "string", "pattern": "^https://.*\\{z\\}.*\\{x\\}.*\\{y\\}" },
        "tilejson": { "type": "string", "pattern": "^https://" },
        "min_zoom": { "type": "integer", "minimum": 0, "maximum": 22 },
        "max_zoom": { "type": "integer", "minimum": 0, "maximum": 22 },
        "attribution": { "type": "array", "minItems": 1, "items": { "type": "string", "minLength": 1 } }
      }
    },
    "basemapSource": {
      "allOf": [{ "$ref": "#/$defs/common" }],
      "unevaluatedProperties": false,
      "properties": {
        "schema": { "const": "shortbread-1.0" },
        "format": { "const": "mvt" }
      }
    },
    "terrainSource": {
      "allOf": [{ "$ref": "#/$defs/common" }],
      "unevaluatedProperties": false,
      "required": ["tile_size"],
      "properties": {
        "schema": { "const": "terrarium" },
        "format": { "enum": ["webp", "png"] },
        "tile_size": { "enum": [256, 512] }
      }
    }
  }
}
```

Note on `unevaluatedProperties`: the `common` definition evaluates the shared keys through `allOf`; `unevaluatedProperties: false` on the source objects then rejects extras (Draft 2020-12 semantics; the `jsonschema` library's `Draft202012Validator` supports it). The test `(["layers","basemap",0,"extra"], 1, "/layers/basemap/0")` pins it.

- [ ] **Step 5: Write `schemas.py`**

```python
# pipeline/src/maqs/schemas.py
"""JSON Schema validation for manifest.json and sources.json.

The schemas in config/schemas/ are the single source of truth. One rule they cannot state,
min_zoom <= max_zoom on a tile source, is checked here after schema validation.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from jsonschema import Draft202012Validator

SCHEMAS_DIR = Path(__file__).resolve().parents[3] / "config" / "schemas"
SIZE_CAP_BYTES = 2_040_109_465  # 1.9 GiB, the same cap validate.py enforces per file


class SchemaError(ValueError):
    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict:
    path = SCHEMAS_DIR / f"{name}.schema.json"
    return json.loads(path.read_text(encoding="utf-8"))


def _pointer(parts) -> str:
    return "/" + "/".join(str(p) for p in parts) if parts else "/"


def validate(instance: object, name: str) -> None:
    """Raise SchemaError for the first violation (deepest path first, then alphabetical)."""
    validator = Draft202012Validator(load_schema(name))
    errors = sorted(validator.iter_errors(instance), key=lambda e: (-len(e.absolute_path), str(list(e.absolute_path)), e.message))
    if errors:
        err = errors[0]
        raise SchemaError(_pointer(err.absolute_path), err.message)
    if name == "sources":
        for layer, entries in instance["layers"].items():  # type: ignore[index]
            for i, src in enumerate(entries):
                if src["min_zoom"] > src["max_zoom"]:
                    raise SchemaError(f"/layers/{layer}/{i}/min_zoom", "min_zoom exceeds max_zoom")
```

Deepest-path-first ordering makes the `where` values in the tests deterministic: `additionalProperties` and `required` errors report the parent object's path (`/regions/0`, `/layers/terrain/0`), value errors report the value's path. If a parametrized case reports a different path than the test expects, fix the TEST's `where` only when the schema genuinely reports a more specific path — never loosen the schema.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `uv run pytest tests/test_schemas.py -q`
Expected: all pass (the `SOURCES` fallback literal is used until Task 4 writes the real file).

- [ ] **Step 7: Lint and commit**

```bash
uv run ruff format . && uv run ruff check .
git add pipeline/pyproject.toml pipeline/uv.lock config/schemas pipeline/src/maqs/schemas.py pipeline/tests/test_schemas.py
git commit -m "feat(pipeline): JSON Schemas for manifest.json and sources.json, validated with jsonschema

Adds jsonschema (MIT) as the one new runtime dependency (ADR 0012)."
```

---

### Task 3: `config/sources.json`

**Files:**
- Create: `config/sources.json`
- Modify: `pipeline/tests/test_schemas.py` (drop the fallback literal: `SOURCES` is always read from the file), `DATA_LICENSE.md` (no text change expected; the agreement test reads it)
- Create: `pipeline/tests/test_sources_file.py`

**Interfaces:**
- Produces: the file clients will fetch from `main`. Values are the live-verified ones in Global Constraints.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_sources_file.py
import json
from pathlib import Path

from maqs.schemas import validate

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "config" / "sources.json"
LICENCE = (ROOT / "DATA_LICENSE.md").read_text(encoding="utf-8")


def test_sources_json_validates_and_names_one_versatiles_source_per_layer():
    doc = json.loads(SOURCES.read_text(encoding="utf-8"))
    validate(doc, "sources")
    assert [s["id"] for s in doc["layers"]["basemap"]] == ["versatiles-osm"]
    assert [s["id"] for s in doc["layers"]["terrain"]] == ["versatiles-elevation"]
    basemap, terrain = doc["layers"]["basemap"][0], doc["layers"]["terrain"][0]
    assert basemap["tiles"] == "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"
    assert basemap["tilejson"] == "https://tiles.versatiles.org/tiles/osm/tiles.json"
    assert (basemap["min_zoom"], basemap["max_zoom"]) == (0, 14)
    assert terrain["tiles"] == "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}"
    assert (terrain["min_zoom"], terrain["max_zoom"], terrain["tile_size"]) == (0, 12, 512)


def test_every_attribution_string_in_sources_json_is_in_data_license():
    doc = json.loads(SOURCES.read_text(encoding="utf-8"))
    for layer in doc["layers"].values():
        for src in layer:
            for text in src["attribution"]:
                assert text in LICENCE, text
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_sources_file.py -q`
Expected: FAIL with `FileNotFoundError` for `config/sources.json`.

- [ ] **Step 3: Write the file**

```json
{
  "sources_version": 1,
  "layers": {
    "basemap": [
      {
        "id": "versatiles-osm",
        "provider": "VersaTiles",
        "tiles": "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
        "tilejson": "https://tiles.versatiles.org/tiles/osm/tiles.json",
        "schema": "shortbread-1.0",
        "format": "mvt",
        "min_zoom": 0,
        "max_zoom": 14,
        "attribution": ["© OpenStreetMap contributors", "CC BY 4.0 ESA WorldCover 2021"]
      }
    ],
    "terrain": [
      {
        "id": "versatiles-elevation",
        "provider": "VersaTiles",
        "tiles": "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}",
        "tilejson": "https://tiles.versatiles.org/tiles/elevation/tiles.json",
        "schema": "terrarium",
        "format": "webp",
        "tile_size": 512,
        "min_zoom": 0,
        "max_zoom": 12,
        "attribution": ["© Mapterhorn"]
      }
    ]
  }
}
```

Then in `tests/test_schemas.py` replace the `SOURCES = … if … else {…}` block with `SOURCES = json.loads((ROOT / "config" / "sources.json").read_text(encoding="utf-8"))`.

- [ ] **Step 4: Run the tests, lint, commit**

Run: `uv run pytest tests/test_sources_file.py tests/test_schemas.py -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

```bash
git add config/sources.json pipeline/tests/test_sources_file.py pipeline/tests/test_schemas.py
git commit -m "feat(config): sources.json with the two VersaTiles tile sources

Values verified against the live TileJSON files on 2026-10-16."
```

---

### Task 4: `maqs check-config`

**Files:**
- Modify: `pipeline/src/maqs/cli.py`, `pipeline/tests/test_cli.py`

**Interfaces:**
- Consumes: `schemas.validate`, `SchemaError`; `_load`, `_config_path`, `_repo_root` from `cli.py`.
- Produces: `check-config [--manifest PATH]`: loads `regions.yaml` (existing `load_config`), validates `<repo root>/config/sources.json` against `sources`, and, when given, `--manifest` against `manifest`; prints one `ok: <file>` line per file; exits 2 (`click.UsageError`) on the first violation with `"<file>: <path>: <message>"`.

- [ ] **Step 1: Write the failing tests**

Append to `pipeline/tests/test_cli.py`:

```python
def check_config(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "check-config", *args])


def test_check_config_passes_on_the_real_files():
    result = check_config()
    assert result.exit_code == 0, result.output
    assert "ok: regions.yaml" in result.output and "ok: sources.json" in result.output


def test_check_config_rejects_a_bad_sources_file(tmp_path):
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    (cfg_dir / "regions.yaml").write_text(REAL.read_text())
    bad = json.loads((REAL.parent / "sources.json").read_text())
    bad["layers"]["basemap"][0]["tiles"] = "http://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"
    (cfg_dir / "sources.json").write_text(json.dumps(bad))
    result = CliRunner().invoke(main, ["--config", str(cfg_dir / "regions.yaml"), "check-config"])
    assert result.exit_code == 2
    assert "sources.json: /layers/basemap/0/tiles" in result.output


def test_check_config_validates_a_manifest(tmp_path):
    from tests.test_schemas import MANIFEST

    good = tmp_path / "manifest.json"
    good.write_text(json.dumps(MANIFEST))
    assert check_config("--manifest", str(good)).exit_code == 0
    bad_doc = json.loads(good.read_text())
    bad_doc["regions"][0]["layers"]["trails"][0]["url"] = (
        "https://github.com/lucavallin/maqs/releases/latest/download/veneto-trails.v1.sqlite"
    )
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(bad_doc))
    result = check_config("--manifest", str(bad))
    assert result.exit_code == 2 and "/regions/0/layers/trails/0/url" in result.output
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_cli.py -k check_config -q`
Expected: FAIL with `No such command 'check-config'` (exit code 2 but no `ok:` output; the first test fails on the assertion).

- [ ] **Step 3: Add the command**

In `pipeline/src/maqs/cli.py`:

```python
import json

from maqs.schemas import SchemaError, validate


def _validate_json_file(path: Path, schema: str) -> None:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise click.UsageError(f"{path.name}: {exc}") from exc
    try:
        validate(doc, schema)
    except SchemaError as exc:
        raise click.UsageError(f"{path.name}: {exc.path}: {exc.message}") from exc
    click.echo(f"ok: {path.name}")


@main.command("check-config")
@click.option(
    "--manifest",
    "manifest_file",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="Also validate this manifest.json against config/schemas/manifest.schema.json.",
)
@click.pass_context
def check_config(ctx: click.Context, manifest_file: Path | None) -> None:
    """Validate regions.yaml, config/sources.json and, optionally, a manifest."""
    config_path = _config_path(ctx)
    _load(config_path)
    click.echo(f"ok: {config_path.name}")
    _validate_json_file(config_path.parent / "sources.json", "sources")
    if manifest_file is not None:
        _validate_json_file(manifest_file, "manifest")
```

Update the module docstring: `"""Command-line entry point: build, regions, check-tools, check-config, manifest."""`.

- [ ] **Step 4: Run the tests, lint, commit**

Run: `uv run pytest tests/test_cli.py -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

```bash
git add pipeline/src/maqs/cli.py pipeline/tests/test_cli.py
git commit -m "feat(pipeline): maqs check-config validates regions.yaml, sources.json and a manifest"
```

---

### Task 5: `manifest.py` — assembly, carry-over, validation

**Files:**
- Create: `pipeline/src/maqs/manifest.py`, `pipeline/tests/test_manifest.py`, `pipeline/tests/manifest_fixtures.py`

**Interfaces:**
- Consumes: `Config`, `Region`, `BasePack`, `config.region_ids(include_fixtures)`, `report_path(out_dir)`, `layers.STANDARD_LAYERS`, `layers.LAYER_SCHEMA_VERSION`, `schemas.validate`, `SchemaError`.
- Produces:
  - `REPO = "lucavallin/maqs"`; `asset_url(release: str, file: str) -> str` → `f"https://github.com/{REPO}/releases/download/{release}/{file}"`.
  - `ATTRIBUTION: tuple[dict, ...]` — the three entries from Global Constraints with `layers` (`OSM`: basemap, trails, places, curvature; `ESA`: basemap; `Mapterhorn`: terrain, terrain-hd).
  - `class ManifestError(ValueError)`.
  - `read_report(dist: Path, label: str) -> dict` (raises `ManifestError("<label>: build-report.json not found")` or `("<label>: build failed: <failures joined>")` when `validation.ok` is false).
  - `entry_from_output(output: dict, release: str) -> dict` → `{layer_schema_version, file, url, bytes, sha256, data_date, osm_timestamp}` plus `role: "overlay"` when `output["file"].endswith(".pmtiles")` and the layer is `trails` or `places`.
  - `region_layers(report: dict, release: str, *, required: Sequence[str]) -> dict[str, list[dict]]` — groups the report's outputs by `output["layer"]`, orders each list by `layer_schema_version` descending then SQLite before overlay, raises `ManifestError("<region>: layer <name> missing")` for a required layer absent or with a failed step.
  - `build_manifest(config: Config, dist: Path, release: str, *, include_fixtures: bool = False, previous: dict | None = None, now: datetime | None = None) -> dict` — validates the result before returning.
  - `carry_over(current: dict, previous: dict) -> dict` — for every region/base pack and layer in `current`, appends entries from `previous` whose `layer_schema_version` is lower than the current minimum for that layer; ignores regions/packs/layers absent from `current`; keeps descending order; returns a new dict.
  - `write_manifest(path: Path, manifest: dict) -> None` (temp file + `replace`).

- [ ] **Step 1: Write the fixture helper**

```python
# pipeline/tests/manifest_fixtures.py
"""Synthetic build reports for manifest tests: no files, no network."""

from __future__ import annotations

import json
from pathlib import Path

from maqs.layers import output_name

SHA = "0123456789abcdef" * 4


def output(label: str, layer: str, ext: str, *, nbytes: int = 1000, ts: str | None = "2026-10-31T20:21:00Z") -> dict:
    return {
        "file": output_name(label, layer, ext),
        "bytes": nbytes,
        "sha256": SHA,
        "tile_type": "mvt" if ext == "pmtiles" else None,
        "min_zoom": 0 if ext == "pmtiles" else None,
        "max_zoom": 14 if ext == "pmtiles" else None,
        "tiles": 10 if ext == "pmtiles" else None,
        "compression": "gzip" if ext == "pmtiles" else None,
        "attribution": None,
        "source_data_date": ts,
        "source": None,
        "layer": layer,
        "layer_schema_version": 1,
        "data_date": "2026-11-01",
    }


def step(name: str, outputs: list[dict], status: str = "built", error: str | None = None) -> dict:
    d = {"name": name, "status": status, "seconds": 1.0, "command": [], "outputs": outputs,
         "anomalies": [], "anomaly_count": 0, "anomaly_kinds": {}}
    if error:
        d["error"] = error
    return d


def region_report(label: str, *, drop: str | None = None, fail: str | None = None) -> dict:
    steps = [
        step("basemap", [output(label, "basemap", "pmtiles", ts="2026-06-07T23:59:58Z")]),
        step("terrain", [output(label, "terrain", "pmtiles", ts=None)]),
        step("trails", [output(label, "trails", "sqlite"), output(label, "trails", "pmtiles")]),
        step("places", [output(label, "places", "sqlite"), output(label, "places", "pmtiles")]),
        step("curvature", [output(label, "curvature", "sqlite")]),
    ]
    steps = [s for s in steps if s["name"] != drop]
    failures = []
    if fail:
        for s in steps:
            if s["name"] == fail:
                s["status"], s["error"], s["outputs"] = "failed", "boom", []
                failures.append(f"{fail}: boom")
    return {"report_version": 1, "region": label, "built_at": "2026-11-01T03:00:00Z",
            "tools": {}, "steps": steps, "validation": {"ok": not failures, "failures": failures}}


def base_report(pack_ids: list[str]) -> dict:
    steps = [step(f"base-{p}", [output(f"base-{p}", "basemap", "pmtiles", ts="2026-06-07T23:59:58Z")]) for p in pack_ids]
    return {"report_version": 1, "region": "base", "built_at": "2026-11-01T03:00:00Z",
            "tools": {}, "steps": steps, "validation": {"ok": True, "failures": []}}


def write_dist(dist: Path, reports: dict[str, dict]) -> Path:
    for label, report in reports.items():
        d = dist / label
        d.mkdir(parents=True, exist_ok=True)
        (d / "build-report.json").write_text(json.dumps(report), encoding="utf-8")
    return dist
```

- [ ] **Step 2: Write the failing tests**

```python
# pipeline/tests/test_manifest.py
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from maqs.config import load_config
from maqs.manifest import (
    ATTRIBUTION,
    ManifestError,
    asset_url,
    build_manifest,
    carry_over,
    entry_from_output,
    read_report,
    write_manifest,
)
from maqs.schemas import validate
from tests.manifest_fixtures import base_report, output, region_report, write_dist

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
NOW = datetime(2026, 11, 1, 3, 12, 44, tzinfo=UTC)
REGIONS = ("triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige")


@pytest.fixture
def cfg():
    return load_config(REAL)


@pytest.fixture
def full_dist(tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["test"] = region_report("test")
    reports["base"] = base_report(["triveneto"])
    return write_dist(tmp_path / "dist", reports)


def test_asset_url_is_tag_pinned():
    assert asset_url("data-2026-11", "veneto-trails.v1.sqlite") == (
        "https://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-trails.v1.sqlite"
    )


def test_entry_from_output_maps_report_fields_and_marks_overlays():
    sqlite = entry_from_output(output("veneto", "trails", "sqlite", nbytes=42), "data-2026-11")
    assert sqlite == {
        "layer_schema_version": 1,
        "file": "veneto-trails.v1.sqlite",
        "url": asset_url("data-2026-11", "veneto-trails.v1.sqlite"),
        "bytes": 42,
        "sha256": "0123456789abcdef" * 4,
        "data_date": "2026-11-01",
        "osm_timestamp": "2026-10-31T20:21:00Z",
    }
    overlay = entry_from_output(output("veneto", "trails", "pmtiles"), "data-2026-11")
    assert overlay["role"] == "overlay"
    assert "role" not in entry_from_output(output("veneto", "basemap", "pmtiles"), "data-2026-11")


def test_build_manifest_assembles_every_region_and_base_pack(cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    validate(m, "manifest")
    assert m["manifest_version"] == 1 and m["release"] == "data-2026-11"
    assert m["created_at"] == "2026-11-01T03:12:44Z" and m["shortbread_version"] == "1.0"
    assert [r["id"] for r in m["regions"]] == list(REGIONS)  # regions.yaml order, fixture excluded
    veneto = next(r for r in m["regions"] if r["id"] == "veneto")
    assert veneto["name"] == {"it": "Veneto", "en": "Veneto"}
    assert veneto["bbox"] == [10.6231, 44.7923, 13.1021, 46.6806]
    assert set(veneto["layers"]) == {"basemap", "terrain", "trails", "places", "curvature"}
    assert [e["file"] for e in veneto["layers"]["trails"]] == ["veneto-trails.v1.sqlite", "veneto-trails.v1.pmtiles"]
    assert veneto["layers"]["trails"][1]["role"] == "overlay"
    assert veneto["layers"]["terrain"][0]["osm_timestamp"] is None
    assert veneto["layers"]["basemap"][0]["osm_timestamp"] == "2026-06-07T23:59:58Z"
    assert m["base"] == [{
        "id": "triveneto", "regions": ["triveneto"], "max_zoom": 10,
        "layers": {"basemap": [entry_from_output(output("base-triveneto", "basemap", "pmtiles", ts="2026-06-07T23:59:58Z"), "data-2026-11")]},
    }]
    assert [a["text"] for a in m["attribution"]] == [a["text"] for a in ATTRIBUTION]


def test_include_fixtures_adds_the_test_region(cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-ci", include_fixtures=True, now=NOW)
    assert m["regions"][0]["id"] == "test"
    validate(m, "manifest")


def test_missing_region_report_fails_naming_it(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS if r != "veneto"}
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: build-report.json not found"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_failed_step_in_a_report_fails(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["veneto"] = region_report("veneto", fail="places")
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: build failed: places: boom"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_missing_layer_fails(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["veneto"] = region_report("veneto", drop="curvature")
    reports["base"] = base_report(["triveneto"])
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="veneto: layer curvature missing"):
        build_manifest(cfg, dist, "data-2026-11", now=NOW)


def test_missing_base_pack_fails_even_with_fixtures(cfg, tmp_path):
    reports = {r: region_report(r) for r in REGIONS}
    reports["test"] = region_report("test")
    dist = write_dist(tmp_path / "dist", reports)
    with pytest.raises(ManifestError, match="base-triveneto"):
        build_manifest(cfg, dist, "data-2026-11", include_fixtures=True, now=NOW)


def test_old_unversioned_files_are_not_picked_up(cfg, full_dist):
    (full_dist / "veneto" / "veneto-trails.sqlite").write_bytes(b"old")
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    files = {e["file"] for r in m["regions"] for layer in r["layers"].values() for e in layer}
    assert "veneto-trails.sqlite" not in files


def test_read_report_errors(tmp_path):
    with pytest.raises(ManifestError, match="veneto: build-report.json not found"):
        read_report(tmp_path, "veneto")


def test_carry_over_keeps_only_lower_versions_of_known_layers(cfg, full_dist):
    current = build_manifest(cfg, full_dist, "data-2026-12", now=NOW)
    for r in current["regions"]:
        for e in r["layers"]["trails"]:
            e["layer_schema_version"] = 2
            e["file"] = e["file"].replace(".v1.", ".v2.")
            e["url"] = e["url"].replace(".v1.", ".v2.")
    previous = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    previous["regions"].append({**previous["regions"][0], "id": "gone"})  # a region no longer configured
    merged = carry_over(current, previous)
    veneto = next(r for r in merged["regions"] if r["id"] == "veneto")
    versions = [e["layer_schema_version"] for e in veneto["layers"]["trails"]]
    assert versions == [2, 2, 1, 1]  # v2 sqlite+overlay first, then the carried v1 pair
    carried = veneto["layers"]["trails"][2]
    assert carried["url"].startswith("https://github.com/lucavallin/maqs/releases/download/data-2026-11/")
    assert [e["layer_schema_version"] for e in veneto["layers"]["places"]] == [1, 1]  # same version: not carried
    assert {r["id"] for r in merged["regions"]} == set(REGIONS)
    validate(merged, "manifest")
    assert current is not merged and current["regions"][1]["layers"]["trails"][0]["layer_schema_version"] == 2


def test_build_manifest_applies_previous(cfg, full_dist):
    previous = build_manifest(cfg, full_dist, "data-2026-10", now=NOW)
    m = build_manifest(cfg, full_dist, "data-2026-11", previous=previous, now=NOW)
    # identical versions: nothing carried, no duplicates
    assert all(len(r["layers"]["trails"]) == 2 for r in m["regions"])


def test_write_manifest_is_atomic_and_pretty(tmp_path, cfg, full_dist):
    m = build_manifest(cfg, full_dist, "data-2026-11", now=NOW)
    out = tmp_path / "out" / "manifest.json"
    write_manifest(out, m)
    assert json.loads(out.read_text()) == m
    assert out.read_text().endswith("}\n") and not (out.parent / "manifest.json.tmp").exists()


def test_attribution_strings_match_data_license():
    licence = (Path(__file__).resolve().parents[2] / "DATA_LICENSE.md").read_text(encoding="utf-8")
    for a in ATTRIBUTION:
        assert a["text"] in licence, a["text"]
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_manifest.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.manifest'`.

- [ ] **Step 4: Write `manifest.py`**

```python
# pipeline/src/maqs/manifest.py
"""Assemble manifest.json from the per-region build reports (docs/data-format.md)."""

from __future__ import annotations

import copy
import json
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

from maqs.config import BasePack, Config, Region
from maqs.layers import STANDARD_LAYERS
from maqs.report import report_path
from maqs.schemas import validate

MANIFEST_VERSION = 1
SHORTBREAD_VERSION = "1.0"
REPO = "lucavallin/maqs"
OVERLAY_LAYERS = frozenset({"trails", "places"})

# Display strings verbatim from DATA_LICENSE.md (a test keeps them in sync).
ATTRIBUTION: tuple[dict, ...] = (
    {
        "text": "© OpenStreetMap contributors",
        "licence": "ODbL 1.0",
        "url": "https://www.openstreetmap.org/copyright",
        "layers": ["basemap", "trails", "places", "curvature"],
    },
    {
        "text": "CC BY 4.0 ESA WorldCover 2021",
        "licence": "CC BY 4.0",
        "url": "https://esa-worldcover.org/en/data-access",
        "layers": ["basemap"],
    },
    {
        "text": "© Mapterhorn",
        "licence": "multiple open licences, listed at url",
        "url": "https://mapterhorn.com/attribution",
        "layers": ["terrain", "terrain-hd"],
    },
)


class ManifestError(ValueError):
    """The dist directory does not hold a complete, successful build."""


def asset_url(release: str, file: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{release}/{file}"


def read_report(dist: Path, label: str) -> dict:
    path = report_path(dist / label)
    if not path.exists():
        raise ManifestError(f"{label}: build-report.json not found")
    report = json.loads(path.read_text(encoding="utf-8"))
    if not report.get("validation", {}).get("ok", False):
        failures = "; ".join(report.get("validation", {}).get("failures", [])) or "unknown"
        raise ManifestError(f"{label}: build failed: {failures}")
    return report


def entry_from_output(output: dict, release: str) -> dict:
    entry = {
        "layer_schema_version": output["layer_schema_version"],
        "file": output["file"],
        "url": asset_url(release, output["file"]),
        "bytes": output["bytes"],
        "sha256": output["sha256"],
        "data_date": output["data_date"],
        "osm_timestamp": output.get("source_data_date"),
    }
    if output["layer"] in OVERLAY_LAYERS and output["file"].endswith(".pmtiles"):
        entry["role"] = "overlay"
    return entry


def _sort_entries(entries: list[dict]) -> list[dict]:
    return sorted(entries, key=lambda e: (-e["layer_schema_version"], "role" in e))


def region_layers(report: dict, release: str, *, required: Sequence[str]) -> dict[str, list[dict]]:
    label = report["region"]
    layers: dict[str, list[dict]] = {}
    for step in report["steps"]:
        if step["status"] == "failed":
            continue
        for output in step["outputs"]:
            layers.setdefault(output["layer"], []).append(entry_from_output(output, release))
    for name in required:
        if not layers.get(name):
            raise ManifestError(f"{label}: layer {name} missing")
    return {name: _sort_entries(entries) for name, entries in layers.items()}


def _region_doc(region: Region, dist: Path, release: str) -> dict:
    report = read_report(dist, region.id)
    return {
        "id": region.id,
        "name": {"it": region.name["it"], "en": region.name["en"]},
        "bbox": list(region.bbox),
        "layers": region_layers(report, release, required=STANDARD_LAYERS),
    }


def _base_docs(config: Config, dist: Path, release: str) -> list[dict]:
    if not config.base_packs:
        return []
    report = read_report(dist, "base")
    by_step = {step["name"]: step for step in report["steps"]}
    docs = []
    for pack in config.base_packs:
        step = by_step.get(f"base-{pack.id}")
        if step is None or step["status"] == "failed" or not step["outputs"]:
            raise ManifestError(f"base-{pack.id}: not built")
        entries = _sort_entries([entry_from_output(o, release) for o in step["outputs"]])
        docs.append(_base_doc(pack, entries))
    return docs


def _base_doc(pack: BasePack, entries: list[dict]) -> dict:
    return {
        "id": pack.id,
        "regions": list(pack.regions),
        "max_zoom": pack.max_zoom,
        "layers": {"basemap": entries},
    }


def carry_over(current: dict, previous: dict) -> dict:
    """Append the previous release's lower-version entries so old clients keep a file to read."""
    merged = copy.deepcopy(current)
    prev_regions = {r["id"]: r for r in previous.get("regions", [])}
    prev_base = {b["id"]: b for b in previous.get("base", [])}
    for doc, prev in [(r, prev_regions.get(r["id"])) for r in merged["regions"]] + [
        (b, prev_base.get(b["id"])) for b in merged["base"]
    ]:
        if prev is None:
            continue
        for layer, entries in doc["layers"].items():
            floor = min(e["layer_schema_version"] for e in entries)
            older = [e for e in prev["layers"].get(layer, []) if e["layer_schema_version"] < floor]
            doc["layers"][layer] = _sort_entries(entries + copy.deepcopy(older))
    return merged


def build_manifest(
    config: Config,
    dist: Path,
    release: str,
    *,
    include_fixtures: bool = False,
    previous: dict | None = None,
    now: datetime | None = None,
) -> dict:
    stamp = (now or datetime.now(UTC)).strftime("%Y-%m-%dT%H:%M:%SZ")
    regions = [
        _region_doc(config.region(rid), dist, release)
        for rid in config.region_ids(include_fixtures=include_fixtures)
    ]
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "created_at": stamp,
        "release": release,
        "shortbread_version": SHORTBREAD_VERSION,
        "attribution": [dict(a) for a in ATTRIBUTION],
        "regions": regions,
        "base": _base_docs(config, dist, release),
    }
    if previous is not None:
        manifest = carry_over(manifest, previous)
    validate(manifest, "manifest")
    return manifest


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)
```

Check `config.region_ids(include_fixtures=...)` preserves `regions.yaml` order with the fixture first when included (the test expects `test` first with `include_fixtures=True`); if the existing method sorts, keep its behaviour and adjust the test's expectation to the method's documented order, stating why.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_manifest.py -q`
Expected: all pass.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff format . && uv run ruff check .
git add pipeline/src/maqs/manifest.py pipeline/tests/test_manifest.py pipeline/tests/manifest_fixtures.py
git commit -m "feat(pipeline): assemble manifest.json from build reports, with carry-over of older schema versions"
```

---

### Task 6: `maqs manifest` command and CI

**Files:**
- Modify: `pipeline/src/maqs/cli.py`, `pipeline/tests/test_cli.py`, `.github/workflows/pipeline.yml`

**Interfaces:**
- Consumes: `build_manifest`, `write_manifest`, `ManifestError`, `SchemaError`.
- Produces: `manifest --release TAG [--dist DIR] [--out PATH] [--previous PATH] [--include-fixtures]`; default `--dist` = `<repo root>/dist`, default `--out` = `<dist>/manifest.json`; prints `wrote <out> (<n> regions, <m> base packs)`; exit 1 (`ClickException`) on `ManifestError`/`SchemaError`/unreadable `--previous`; `--release` must match `^data-\d{4}-\d{2}$` or exit 2 (`UsageError`) — `data-ci` is accepted only together with `--include-fixtures` (CI's smoke build), otherwise exit 2.

- [ ] **Step 1: Write the failing tests**

Append to `pipeline/tests/test_cli.py`:

```python
from tests.manifest_fixtures import base_report, region_report, write_dist

ALL_REGIONS = ("triveneto", "veneto", "friuli-venezia-giulia", "trentino-alto-adige")


def manifest_cmd(*args: str):
    return CliRunner().invoke(main, ["--config", str(REAL), "manifest", *args])


def full_dist(tmp_path):
    reports = {r: region_report(r) for r in ALL_REGIONS}
    reports["test"] = region_report("test")
    reports["base"] = base_report(["triveneto"])
    return write_dist(tmp_path / "dist", reports)


def test_manifest_command_writes_a_valid_manifest(tmp_path):
    dist = full_dist(tmp_path)
    result = manifest_cmd("--release", "data-2026-11", "--dist", str(dist))
    assert result.exit_code == 0, result.output
    out = dist / "manifest.json"
    assert "wrote" in result.output and out.exists()
    doc = json.loads(out.read_text())
    assert doc["release"] == "data-2026-11" and [r["id"] for r in doc["regions"]] == list(ALL_REGIONS)
    assert check_config("--manifest", str(out)).exit_code == 0


def test_manifest_command_fails_on_a_missing_region(tmp_path):
    dist = full_dist(tmp_path)
    (dist / "veneto" / "build-report.json").unlink()
    result = manifest_cmd("--release", "data-2026-11", "--dist", str(dist))
    assert result.exit_code == 1 and "veneto: build-report.json not found" in result.output
    assert not (dist / "manifest.json").exists()


def test_manifest_command_rejects_a_bad_release_tag(tmp_path):
    dist = full_dist(tmp_path)
    assert manifest_cmd("--release", "latest", "--dist", str(dist)).exit_code == 2
    assert manifest_cmd("--release", "data-ci", "--dist", str(dist)).exit_code == 2
    ok = manifest_cmd("--release", "data-ci", "--dist", str(dist), "--include-fixtures")
    assert ok.exit_code == 0, ok.output
    assert json.loads((dist / "manifest.json").read_text())["regions"][0]["id"] == "test"


def test_manifest_command_applies_previous(tmp_path):
    dist = full_dist(tmp_path)
    previous = tmp_path / "previous.json"
    assert manifest_cmd("--release", "data-2026-10", "--dist", str(dist), "--out", str(previous)).exit_code == 0
    # The new build ships curvature schema 2; the previous release's v1 entries must be carried over.
    report_file = dist / "veneto" / "build-report.json"
    report = json.loads(report_file.read_text())
    for s in report["steps"]:
        if s["name"] == "curvature":
            s["outputs"][0]["layer_schema_version"] = 2
            s["outputs"][0]["file"] = s["outputs"][0]["file"].replace(".v1.", ".v2.")
    report_file.write_text(json.dumps(report))
    result = manifest_cmd("--release", "data-2026-11", "--dist", str(dist), "--previous", str(previous))
    assert result.exit_code == 0, result.output
    doc = json.loads((dist / "manifest.json").read_text())
    veneto = next(r for r in doc["regions"] if r["id"] == "veneto")
    assert [e["layer_schema_version"] for e in veneto["layers"]["curvature"]] == [2, 1]
    assert veneto["layers"]["curvature"][1]["url"].endswith("/data-2026-10/veneto-curvature.v1.sqlite")
    other = next(r for r in doc["regions"] if r["id"] == "triveneto")
    assert [e["layer_schema_version"] for e in other["layers"]["curvature"]] == [1]  # same version: not carried
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_cli.py -k manifest_command -q`
Expected: FAIL with `No such command 'manifest'`.

- [ ] **Step 3: Add the command**

```python
import re

from maqs.manifest import ManifestError, build_manifest, write_manifest

RELEASE_TAG = re.compile(r"^data-\d{4}-\d{2}$")
CI_RELEASE = "data-ci"


@main.command()
@click.option("--release", required=True, help="Release tag, data-YYYY-MM (data-ci with --include-fixtures).")
@click.option("--dist", type=click.Path(path_type=Path), default=None, show_default="dist/ under the repo root")
@click.option("--out", type=click.Path(path_type=Path), default=None, show_default="<dist>/manifest.json")
@click.option("--previous", type=click.Path(path_type=Path, exists=True, dir_okay=False), default=None,
              help="The latest published manifest; its lower schema versions are carried over.")
@click.option("--include-fixtures", is_flag=True, help="Include fixture regions (CI smoke build only).")
@click.pass_context
def manifest(ctx: click.Context, release: str, dist: Path | None, out: Path | None,
             previous: Path | None, include_fixtures: bool) -> None:
    """Assemble and validate manifest.json from every region's build report."""
    config_path = _config_path(ctx)
    cfg = _load(config_path)
    if release == CI_RELEASE and not include_fixtures:
        raise click.UsageError(f"--release {CI_RELEASE} is only valid with --include-fixtures")
    if release != CI_RELEASE and not RELEASE_TAG.match(release):
        raise click.UsageError(f"--release must look like data-YYYY-MM, got '{release}'")
    if dist is None:
        dist = _repo_root(config_path) / "dist"
    if out is None:
        out = dist / "manifest.json"
    prev_doc = None
    if previous is not None:
        try:
            prev_doc = json.loads(previous.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise click.ClickException(f"--previous {previous}: {exc}") from exc
    try:
        doc = build_manifest(cfg, dist, release, include_fixtures=include_fixtures, previous=prev_doc)
    except (ManifestError, SchemaError) as exc:
        raise click.ClickException(str(exc)) from exc
    write_manifest(out, doc)
    click.echo(f"wrote {out} ({len(doc['regions'])} regions, {len(doc['base'])} base packs)")
```

The `data-ci` tag does not match the schema's `release` pattern: make the schema accept it too — change `"release": { "type": "string", "pattern": "^data-(\\d{4}-\\d{2}|ci)$" }` in `manifest.schema.json`, add `(["release"], "data-ci", …)` as a VALID case (not in the invalid list) in `test_schemas.py`, and keep `url`'s pattern allowing `data-ci` the same way (`data-(\\d{4}-\\d{2}|ci)`). Document in data-format.md that `data-ci` manifests are never published.

- [ ] **Step 4: Run the tests, lint**

Run: `uv run pytest -q && uv run ruff format . && uv run ruff check .`
Expected: all pass.

- [ ] **Step 5: CI**

In `.github/workflows/pipeline.yml`, smoke job, after the `cat dist/test/build-report.json` step and before the network test:

```yaml
      - name: Assemble and validate a CI manifest from the test build
        run: |
          uv run maqs manifest --release data-ci --dist "$GITHUB_WORKSPACE/dist" --include-fixtures
          uv run maqs check-config --manifest "$GITHUB_WORKSPACE/dist/manifest.json"
        working-directory: pipeline
```

This needs `dist/base/` too (the manifest requires every configured base pack): add, right before it, `- run: uv run maqs build --region base --dist "$GITHUB_WORKSPACE/dist" --cache "$GITHUB_WORKSPACE/.cache"` with `working-directory: pipeline` (the base pack is a 13 MB range-request extract, about 10 s; ADR 0007). Add `dist/manifest.json` to the artifact: change the upload `path:` to a two-line list `dist/test` and `dist/manifest.json`. Validate the YAML from the repo root: `python3 -I -c "import yaml; yaml.safe_load(open('.github/workflows/pipeline.yml')); print('yaml ok')"` (use `uv run --with pyyaml python -I …` from `pipeline/` with the relative path `../.github/…` if the system Python lacks PyYAML).

- [ ] **Step 6: Commit (no push yet; Task 7 pushes once)**

```bash
git add pipeline/src/maqs/cli.py pipeline/tests/test_cli.py pipeline/tests/test_schemas.py config/schemas/manifest.schema.json .github/workflows/pipeline.yml
git commit -m "feat(pipeline): maqs manifest command; CI assembles and validates a manifest from the test build"
```

---

### Task 7: Documentation, ADR 0012, push

**Files:**
- Modify: `docs/data-format.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: `docs/data-format.md`**

Replace line 9's sentence ("The tile archives carry no `layer_schema_version` yet …") with the tile layers' version-1 definitions (basemap: Shortbread 1.0, gzip MVT, z0–14, one-tile border except fixtures; terrain: terrarium WebP 512 px z0–12; terrain-hd: same encoding, higher zoom), and state the output-name rule `<label>-<layer>.v<N>.<ext>` once near the top; update every file name in the document to the `.v1.` form. Add two sections before "Build report":

- **`manifest.json` (`manifest_version` 1)** — the structure (reproduce the spec's abridged example with real test-region values from a `maqs manifest --include-fixtures` run on a local test build, so the example is true), every field with its rule, the ordering rule (highest version first, SQLite before its overlay with `role: "overlay"`), tag-pinned URLs, `osm_timestamp` meaning per layer (basemap: planetiler replication time; SQLite layers: the Geofabrik extract's timestamp; terrain: null), the attribution list, the `base` list, the fixture exclusion, `data-ci` never published. Then **Compatibility rule** as a sub-heading: the client algorithm (pick the first supported version per layer; none → not available; unknown `manifest_version` → typed error and keep the cached manifest; ignore unknown fields; additive changes keep the version) and the **producer rule** (a bump ships both versions for one release via carry-over; the next release drops the old one; `url` may point at the previous tag).
- **`sources.json` (`sources_version` 1)** — the structure (the real file), each field, the live-verified facts with date (2026-10-16), the fallback rule (clients keep a bundled copy), and that editing it on `main` is a production change.

In "Build report": document the three new output fields. In "Validation rules": the schema checks `check-config` performs and what `maqs manifest` checks in code (completeness, failed reports, base packs).

- [ ] **Step 2: `docs/architecture.md`**

In "Pipeline": a paragraph on the release artefacts — per-region reports → `maqs manifest` → `dist/manifest.json` → (Phase 3) release assets and `manifest.json`; the carry-over step's place in a release; `check-config` as the CI gate on `sources.json`. Under "CI": the smoke job now also builds the base pack and assembles/validates a `data-ci` manifest; the artifact gains `manifest.json`. Under "Swift package": the two client fetch paths (`releases/latest/download/manifest.json`; `raw.githubusercontent.com/…/config/sources.json`) and the compatibility rule by reference to data-format.md.

- [ ] **Step 3: `docs/decisions.md` — ADR 0012**

Append in the existing format (`## 0012 — Manifest, sources and the compatibility rule`; date 2026-10-16; status accepted (owner decision 2026-10-16)):
- Context: brief Phase 2; shipped apps parse these files; fragmented schema evolution; the `base` pack (ADR 0007); the basemap lag (ADR 0004).
- Decision: side-by-side schema versions for one release window; versioned asset names from the first release; tag-pinned URLs; strict producer / tolerant consumer; `jsonschema` 4.x (MIT) as the validator and only new dependency; assembly by `maqs manifest`; `check-config` as the gate; the VersaTiles facts verified live on 2026-10-16 (both TileJSON URLs, zoom ranges, `tile_schema` values, attribution strings, basemap replication time 2026-06-07T23:59:58Z).
- Rejected: "unavailable, never broken" (an old app silently loses a layer); "additive forever" (forecloses schema repair before Phase 4 exists); workflow-side `jq` assembly (no validation at the point of writing, no tests).
- Consequences: one layer's assets double for one month after a bump; Phase 3 must download the latest manifest before assembling and re-upload or keep the carried files; Phase 4 implements the client algorithm exactly as data-format.md states; the `curvature` size question (ADR 0011) is unaffected.

- [ ] **Step 4: `README.md` and `CLAUDE.md`**

README: in the data section, name the manifest URL clients read and the `sources.json` path, link data-format.md's compatibility rule; the build example's output list uses the `.v1.` names; the Develop block adds `uv run maqs check-config` and `uv run maqs manifest --release data-ci --include-fixtures`.

CLAUDE.md §1: Commands gain `uv run maqs check-config` and `uv run maqs manifest --release data-YYYY-MM [--previous …]`; the repository map gains `config/schemas/`, `config/sources.json` (already listed as planned — mark real), `pipeline/src/maqs/{layers,schemas,manifest}.py`; "Things that will bite you" gains: "Every manifest `url` is tag-pinned; only `manifest.json` itself is fetched through `releases/latest/download/`. A `latest` URL inside the manifest fails the schema." and "Output files carry the schema version (`veneto-trails.v1.sqlite`); a `dist/` from before 2026-10-16 is rebuilt, not reused." Fix the Conventions line about `config/sources.json` if it still says "to be added".

- [ ] **Step 5: Humanizer pass, lint, commit, push, watch CI**

Run the `humanizer` skill over the README and ADR text; apply. Then from `pipeline/`: `uv run ruff check .` (no code changed; sanity). Then:

```bash
git add docs/data-format.md docs/architecture.md docs/decisions.md README.md CLAUDE.md
git commit -m "docs: manifest and sources formats, the compatibility rule, ADR 0012"
git push origin main
gh run watch --exit-status
```

Expected: green; the smoke job shows `wrote …/dist/manifest.json (1 regions, 1 base packs)` and `ok: manifest.json`; the artifact lists `manifest.json`. Record the run id and the smoke duration in the report.

---

## Self-review notes

- **Spec coverage:** goal and success criteria (Tasks 1–7); manifest format and rules (Task 2 schema, Task 5 assembly, Task 7 docs); compatibility and producer rules (Task 5 carry-over, Task 7 docs); `sources.json` (Task 3) with live verification recorded (Global Constraints, ADR 0012); schemas (Task 2); pipeline changes — `layers.py`, renames, report fields (Task 1), `manifest.py` (Task 5), CLI (Tasks 4, 6), dependency (Task 2); docs (Task 7); tests as the spec lists (Tasks 1–6); CI (Task 6). Out of scope unchanged.
- **Type consistency:** `output_name(label, layer, ext)`, `LAYER_SCHEMA_VERSION`, `STANDARD_LAYERS` (Task 1) used in Tasks 5–6 and fixtures; `SchemaError(path, message)` / `validate(instance, name)` (Task 2) used in Tasks 4–6; `ManifestError`, `build_manifest(config, dist, release, *, include_fixtures, previous, now)`, `write_manifest`, `entry_from_output`, `carry_over`, `read_report`, `asset_url`, `ATTRIBUTION` (Task 5) used in Task 6 and its tests; `OutputInfo.layer/layer_schema_version/data_date` (Task 1) read by `entry_from_output` and produced by the fixtures.
- **Review Focus coverage:** (1) `test_failed_step_in_a_report_fails`; (2) `test_carry_over_keeps_only_lower_versions_of_known_layers`, `test_build_manifest_applies_previous`; (3) `test_invalid_sources_name_the_offending_path`, `test_invalid_manifests_name_the_offending_path`, `test_check_config_rejects_a_bad_sources_file`, `test_check_config_validates_a_manifest`; (4) `test_missing_base_pack_fails_even_with_fixtures`; (5) `test_output_name_carries_the_schema_version` plus every step test's renamed outputs, `test_old_unversioned_files_are_not_picked_up`.
- **Known plan adjustments inside tasks:** Task 6 amends the `release`/`url` patterns to accept `data-ci` (CI-only) — the spec's pattern was `^data-\d{4}-\d{2}$`; this is recorded in data-format.md as "never published". Task 5 notes `region_ids` ordering; Task 2 notes the one in-code check (`min_zoom ≤ max_zoom`).
