# Manifest and config formats (Phase 2) — design

**Date:** 2026-10-16 · **Status:** approved in conversation; spec under review
**Brief:** `docs/BRIEF.md` § Phase 2 · **Builds on:** ADR 0001 (Shortbread 1.0 pin), ADR 0004 (one provider), ADR 0007/0009 (base pack, fixtures), ADR 0010/0011 (data layers)

## Goal

Define the two files every client reads — `manifest.json` (per data release, from GitHub Releases) and `config/sources.json` (from `main`) — as versioned, schema-validated formats with a written compatibility rule, and give the pipeline the commands that produce and check them, so Phase 3's workflow only calls commands and Phase 4's Swift reader is written against a fixed contract.

## Success criteria

- `uv run maqs manifest --release data-2026-11 --dist dist` on a `dist/` holding every non-fixture region (all five layers) plus the base pack writes `dist/manifest.json` that validates against `config/schemas/manifest.schema.json`, and exits 1 with a clear message when any region, layer or the base pack is missing or any asset exceeds 1.9 GiB.
- `uv run maqs check-config` validates `config/regions.yaml` (existing checks), `config/sources.json` (against `sources.schema.json`) and, with `--manifest <path>`, a manifest; exit 2 on a violation, with the JSON path of the offending value.
- The compatibility rule is written once in `docs/data-format.md` and exercised by a test: an old manifest's lower-version entries are carried over by `--previous` and a client that supports only the lower version can still select them.
- `config/sources.json` exists, validates, and every URL and zoom in it was checked live (the ADR records the date and what was checked).
- The pipeline's output names carry the schema version (`<label>-<layer>.v<N>.<ext>`); `build-report.json` records `layer_schema_version`, `data_date` and `osm_timestamp` per output.
- CI's smoke job runs `maqs manifest --include-fixtures` on the test build and `maqs check-config`.
- Unit tests: 100 % of the schema constraints have a valid and an invalid case; manifest assembly, carry-over, missing-input failures and URL formation are tested on fixture reports; nothing touches the network.

## Decisions (approved 2026-10-16)

1. **Compatibility rule: side-by-side versions for one release window.** When a layer's schema changes incompatibly, the next release ships both the new file and the previous schema's file for that layer, for one monthly cycle. The manifest lists every version per layer, highest first. A client selects the highest `layer_schema_version` it supports; if none matches, that layer is *not available* for that region (typed error on the client; other layers unaffected). An unknown `manifest_version` is a typed error. Clients ignore unknown fields.
2. **Assembly by a pipeline command**, `maqs manifest`, not by the workflow. Validation happens where the file is written.
3. **Versioned asset names from the first release:** `<label>-<layer>.v<N>.<ext>`, so two schema versions of one layer can coexist in a release. Tile layers get `layer_schema_version` 1 (basemap: Shortbread 1.0, gzip MVT, z0–14; terrain: terrarium WebP 512 px, z0–12).
4. **`jsonschema` (Python, MIT) is the validator**, added as a runtime dependency and recorded in ADR 0012. Draft 2020-12 schemas are the single source of truth; no hand-written duplicate checks beyond what the schema cannot express (listed below).

## `manifest.json` — manifest_version 1

Published as a release asset named `manifest.json`. The example below is abridged (quoted `…` strings stand for full entries). Clients fetch `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json`; every `url` inside is **tag-pinned**, never `latest`, so a manifest and its files always agree.

```json
{
  "manifest_version": 1,
  "created_at": "2026-11-01T03:12:44Z",
  "release": "data-2026-11",
  "shortbread_version": "1.0",
  "attribution": [
    { "text": "© OpenStreetMap contributors", "licence": "ODbL 1.0", "url": "https://www.openstreetmap.org/copyright", "layers": ["basemap", "trails", "places", "curvature"] },
    { "text": "CC BY 4.0 ESA WorldCover 2021", "licence": "CC BY 4.0", "url": "https://esa-worldcover.org/en/data-access", "layers": ["basemap"] },
    { "text": "© Mapterhorn", "licence": "multiple open licences, listed at url", "url": "https://mapterhorn.com/attribution", "layers": ["terrain"] }
  ],
  "regions": [
    {
      "id": "veneto",
      "name": { "it": "Veneto", "en": "Veneto" },
      "bbox": [10.6231, 44.7923, 13.1021, 46.6806],
      "layers": {
        "basemap":   [ { "layer_schema_version": 1, "file": "veneto-basemap.v1.pmtiles", "url": "https://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-basemap.v1.pmtiles", "bytes": 238114816, "sha256": "…64 hex…", "data_date": "2026-11-01", "osm_timestamp": "2026-06-07T20:21:00Z" } ],
        "terrain":   [ { "layer_schema_version": 1, "file": "veneto-terrain.v1.pmtiles", "url": "…", "bytes": 0, "sha256": "…", "data_date": "2026-11-01", "osm_timestamp": null } ],
        "trails":    [ { "layer_schema_version": 1, "file": "veneto-trails.v1.sqlite", "url": "…", "bytes": 0, "sha256": "…", "data_date": "2026-11-01", "osm_timestamp": "2026-10-31T20:21:00Z" },
                       { "layer_schema_version": 1, "file": "veneto-trails.v1.pmtiles", "url": "…", "bytes": 0, "sha256": "…", "data_date": "2026-11-01", "osm_timestamp": "2026-10-31T20:21:00Z", "role": "overlay" } ],
        "places":    [ "… sqlite entry …", "… overlay entry with role overlay …" ],
        "curvature": [ "… sqlite entry …" ]
      }
    }
  ],
  "base": [
    { "id": "triveneto", "regions": ["triveneto"], "max_zoom": 10,
      "layers": { "basemap": [ { "layer_schema_version": 1, "file": "base-triveneto-basemap.v1.pmtiles", "url": "…", "bytes": 0, "sha256": "…", "data_date": "2026-11-01", "osm_timestamp": "…" } ] } }
  ]
}
```

Rules:

- **Top level:** `manifest_version` (integer, 1), `created_at` (ISO 8601 UTC, `Z`), `release` (`^data-\d{4}-\d{2}$`), `shortbread_version` (`"1.0"`), `attribution` (non-empty list), `regions` (non-empty list), `base` (list, may be empty). Nothing else.
- **Attribution entry:** `text` (the required display string, verbatim from `DATA_LICENSE.md`), `licence`, `url`, `layers` (which layers need it). The list is assembled from constants in the pipeline that mirror `DATA_LICENSE.md`; a test asserts the two agree on `text`.
- **Region:** `id` (kebab-case, `^[a-z0-9]+(-[a-z0-9]+)*$`), `name` (`it` and `en`, both required), `bbox` (`[lon_min, lat_min, lon_max, lat_max]`, WGS 84), `layers` (object whose keys are exactly the five standard layers; `terrain-hd` appears only when built). Fixture regions never appear.
- **Layer entry:** `layer_schema_version` (integer ≥ 1), `file` (`^[a-z0-9-]+-(basemap|terrain|terrain-hd|trails|places|curvature)\.v[0-9]+\.(pmtiles|sqlite)$`), `url` (`^https://github\.com/lucavallin/maqs/releases/download/data-\d{4}-\d{2}/` followed by `file`), `bytes` (integer, 1 … 2,040,109,465 = 1.9 GiB), `sha256` (`^[0-9a-f]{64}$`), `data_date` (`YYYY-MM-DD`, the build date), `osm_timestamp` (ISO 8601 UTC or null), optional `role` = `"overlay"` for the trails/places tile archives. A layer's list is ordered by `layer_schema_version` descending; within one version the SQLite entry precedes its overlay. Entries of one version share `data_date`.
- **Base pack:** `id`, `regions` (the region ids it covers), `max_zoom`, `layers` with `basemap` only (ADR 0007); file `base-<pack>-basemap.v<N>.pmtiles`.
- **Compatibility rule (the contract, repeated in `docs/data-format.md`):** a client knows the set of `layer_schema_version`s it can read per layer. For each region and layer it takes the first entry whose version is in that set. No match → the layer is *not available* in that region for this client; the client shows its other layers and may tell the user to update. `manifest_version` not equal to a known value → the whole manifest is rejected with a typed error and the client keeps using its last cached manifest. Unknown fields anywhere are ignored. Adding a field or a new layer key is additive and keeps `manifest_version`; renaming, removing or changing the meaning of a field bumps it.
- **Producer rule for a schema bump:** the release that introduces `v(N+1)` for a layer also carries the `vN` files for one release; the following release drops them. `maqs manifest --previous` implements the carry-over: every entry of the previous manifest whose `layer_schema_version` is lower than the current one for that region and layer is copied verbatim (same `url`, pointing at the previous tag, same `sha256`); entries with the current version are never carried. Phase 3 decides whether to re-upload the old files under the new tag or keep the old tag's URL; the format allows both because `url` is per entry.

What the schema cannot express and the command checks in code: every non-fixture region in `regions.yaml` appears with every standard layer; every configured base pack appears; the `file` in each entry matches `url`'s last path segment; `bytes` and `sha256` equal the build report's values; the attribution list covers every layer present; `created_at` is not older than the newest report's `built_at`.

## `config/sources.json` — sources_version 1

Fetched by clients from `https://raw.githubusercontent.com/lucavallin/maqs/main/config/sources.json`, cached, with a bundled copy as fallback (Phase 4). Editing it is a production change (CLAUDE.md).

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

Rules: `layers` has exactly `basemap` and `terrain`; each is an ordered, non-empty list (priority order; today one entry each per ADR 0004); `tiles` and `tilejson` are HTTPS; `tiles` contains `{z}`, `{x}` and `{y}`; `schema` is `shortbread-1.0` for basemap and `terrarium` for terrain; `format` ∈ `mvt` | `webp` | `png`; `tile_size` ∈ 256 | 512 (required for terrain); `0 ≤ min_zoom ≤ max_zoom ≤ 22`; `attribution` non-empty, strings verbatim from `DATA_LICENSE.md`. The exact `tilejson` URL and zooms are verified against the live TileJSON before the file is written; the ADR records the check. Compatibility: unknown fields ignored; `sources_version` bump on a structural change; a client that cannot parse the file falls back to its bundled copy.

## JSON Schemas — `config/schemas/`

`manifest.schema.json` and `sources.schema.json`, Draft 2020-12, `$id` set to the file's raw-GitHub URL, `additionalProperties: false` throughout (the producer is strict; consumers are tolerant by rule). Patterns and bounds as listed above. The schemas are data: no generated code, no duplicate validation of what they express.

## Pipeline changes

- **`maqs/layers.py` (new):** `LAYER_SCHEMA_VERSION: dict[str, int]` = `{basemap: 1, terrain: 1, terrain-hd: 1}` merged with `sqlite_out.SCHEMA_VERSION` (trails, places, curvature → 1); `output_name(label, layer, ext) -> str` = `f"{label}-{layer}.v{version}.{ext}"`; `STANDARD_LAYERS` (the five). Every step's `outputs()` uses `output_name`; the trails step reads `output_name(label, "terrain", "pmtiles")`.
- **Build report (report_version stays 1, additive):** each output gains `layer` (the step's layer name), `layer_schema_version`, `data_date` (the build date, `YYYY-MM-DD`) and keeps `source_data_date` (renamed in the manifest to `osm_timestamp`). `OutputInfo` gains `layer` and `layer_schema_version`.
- **`maqs/manifest.py` (new):** `read_region_report(dist, region) -> dict`, `manifest_entry(output: dict, release: str) -> dict`, `build_manifest(config, dist, release, *, include_fixtures=False, previous: dict | None = None, now: datetime | None = None) -> dict`, `carry_over(current: dict, previous: dict) -> dict`, `validate(instance, schema_name) -> None` (raises `SchemaError(path, message)`), `ATTRIBUTION` constants (text, licence, url, layers), `REPO = "lucavallin/maqs"`, `asset_url(release, file)`.
- **CLI:** `maqs manifest --release TAG [--dist DIR] [--out PATH] [--previous PATH] [--include-fixtures]` (exit 1 on a missing input or a validation failure, message lists what is missing); `maqs check-config [--manifest PATH]` (exit 2 on a violation with the JSON path). `regions` and `build` unchanged except for the output names.
- **Validation of `bytes`:** the 1.9 GiB cap is already enforced per file at build time; the schema repeats it so a hand-edited manifest cannot pass.
- **Dependency:** `jsonschema>=4.23` in `pyproject.toml`, `uv lock`.

## Docs

- `docs/data-format.md`: new sections "manifest.json" and "sources.json" (formats, every field, the compatibility rule, the producer rule for bumps, asset naming), and the tile layers' `layer_schema_version` 1 definitions; the output-name change in every existing section.
- `docs/decisions.md`: **ADR 0012 — Manifest, sources and the compatibility rule**: context (brief Phase 2, old clients, fragmented data), decision (side-by-side window, versioned names, tag-pinned URLs, strict producer / tolerant consumer, `jsonschema`), rejected (unavailable-only, additive-forever, workflow-side `jq`), consequences (asset count during a window, Phase 3 carry-over step, Phase 4 parse rules), the live-verified VersaTiles facts with date.
- `docs/architecture.md`: the release artefact flow (reports → manifest → release) and the client fetch paths.
- `README.md`: the manifest URL and what clients read; `CLAUDE.md` §1: commands (`maqs manifest`, `maqs check-config`), repo map (`config/schemas/`, `maqs/manifest.py`, `maqs/layers.py`), a trap ("every manifest URL is tag-pinned; `releases/latest/download/` is only for `manifest.json` itself").

## Tests

- `tests/test_schemas.py`: each schema accepts the documented example; one invalid instance per constraint (bad sha256, `latest` URL, bytes over cap, missing `en` name, extra field, wrong `shortbread_version`, zoom out of range, `tiles` without `{z}`, empty attribution).
- `tests/test_manifest.py`: fixture reports for two regions plus a base pack → manifest assembled, ordered, validates; URL formation; `bytes`/`sha256` copied from the report; fixtures excluded unless `--include-fixtures`; a missing region, missing layer or missing base pack fails naming it; `carry_over` keeps lower versions from the previous manifest, drops equal/higher ones, preserves their URLs; `created_at` injectable.
- `tests/test_cli.py`: `manifest` and `check-config` exit codes and messages; `check-config` on the real `config/sources.json` and `regions.yaml` passes.
- `tests/test_layers.py`: `output_name` and the version map; every step's `outputs()` ends in `.v1.<ext>`.
- Existing step and network tests updated for the new names (deliberate, in their own commit).
- `DATA_LICENSE.md` ↔ `ATTRIBUTION` agreement test.

## CI

`pipeline.yml` smoke job: after the build, `uv run maqs manifest --release data-ci --dist "$GITHUB_WORKSPACE/dist" --include-fixtures` and `uv run maqs check-config --manifest dist/manifest.json`; the artifact gains `manifest.json`. The unit job already runs the schema tests.

## Out of scope (Phase 3 / Phase 4)

The release workflow, uploading assets, downloading the previous manifest, marking latest; the Swift parsers and the bundled `sources.json` copy; ETag handling. Nothing here references the consuming apps.

## Risks

- Renaming outputs touches every step and test; mitigated by one helper and one deliberate test-update commit.
- A future provider swap edits `sources.json` on `main` and reaches apps at once; mitigated by `check-config` in CI and the production-change rule in CLAUDE.md.
- The side-by-side window doubles one layer's assets for a month; acceptable against the 1.9 GiB per-asset cap (sizes measured in ADR 0011).
