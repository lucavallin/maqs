# Architecture

## Pipeline (`pipeline/`)

A thin Python orchestrator around pinned CLIs. One map provider, VersaTiles, supplies every tile online and offline ([ADR 0004](decisions.md)). Geofabrik will supply the OSM data for the data layers (trails, places, curvature), which the pipeline does not build yet.

- **Entry point:** `uv run maqs build --region <id>|all|base [--layers …] [--force] [--dist DIR] [--cache DIR]`, plus `maqs regions` and `maqs check-tools`, run from `pipeline/`. `--layers` defaults to `basemap,terrain`; `terrain-hd` is opt-in. `--region all` builds every region, the `test` fixture included; `--region base` builds the base packs. A usage error exits 2; a tool, configuration or build failure exits 1.
- **Configuration:** `config/regions.yaml`, loaded and checked by `maqs/config.py`. Top level: `schema_version` (1), `hd_max_zoom` (default 13), `base_packs` and `regions` (both lists of mappings). A malformed file, YAML syntax included, is a configuration error (exit 1) that names what is wrong. A region has an `id` (lowercase kebab-case; `all` and `base` are reserved for `--region`), `name` with `it` and `en`, a `bbox` (`[lon_min, lat_min, lon_max, lat_max]`, not crossing the antimeridian), and optionally `bbox_border` (tiles of margin around the bbox at every zoom, an integer ≥ 0, default 1), `fixture` (`true` or `false`; a fixture is built for tests and CI only), `hd_max_zoom` (≥ 13), `osm.geofabrik` (the Geofabrik extract its data layers will read) and `clip.admin` (OSM relation ids the data layers will be cut by). A base pack has an `id` (same rules), the `regions` it covers (never a fixture) and a `max_zoom` (0–14, default 10). A region is the smallest unit a pack is cut at, and regions can be anywhere in the world ([ADR 0009](decisions.md)).
- **Steps:** `maqs/steps/`. Each step implements `outputs(ctx)`, `expectation(ctx)` and `build(ctx)`. The runner (`steps/base.py`) skips a step whose outputs all exist unless `--force` is given. It then validates every output, skipped ones included, so a truncated file from a crashed run is caught and reported with a `--force` hint. A tool failure, a missing tool, a filesystem error or a failed check marks the step failed in the report and the build goes on to the next region (`--region all`); any other exception is a bug and stops the build.
- **Tools:** `maqs/tools.py` is the only place a subprocess starts: no shell, the exact command logged, a non-zero exit raised as `ToolError`. Version pins live in `PINS` and in `pipeline/bootstrap.sh`. `check-tools`, which `build` also runs before any step, fails on a missing tool or a version mismatch. Homebrew's `pmtiles` reports `dev` and is accepted with a note, since its version cannot be checked.
- **Validation and report:** `maqs/validate.py` reads each archive's PMTiles header and metadata directly (`maqs/pmtiles_header.py`, no tool output parsing) and `maqs/report.py` writes `build-report.json`. The formats and the validation rules are in [`docs/data-format.md`](data-format.md).
- **Directories:** `.cache/` for downloads and `dist/<region>/` for outputs, both gitignored; nothing generated is ever committed. When `--dist` or `--cache` is omitted, both sit under the repository root (the parent of the `config/` directory holding `regions.yaml`), so a build run from `pipeline/` still writes to the root `dist/`. A path given explicitly is relative to the current directory.

### Tile layers

`versatiles convert --bbox …` reads the planet archives by HTTP range requests, so nothing downloads the planet. It adds `--bbox-border N` only when the region's `bbox_border` is above 0. The border keeps the map from going blank at the region's edge; the `test` fixture sets it to 0 to stay small ([ADR 0009](decisions.md)). The basemap is written with `--compress gzip` because MapLibre rejects brotli. Terrain is cut at z0–12 and left as stored. A base pack is the basemap over the union bbox of its regions, up to its `max_zoom`, with no border.

`terrain-hd` is opt-in. It reads Mapterhorn's zoom-6 regional archives (`6-<x>-<y>.pmtiles`) with `pmtiles extract`, after a `--dry-run` per archive to skip the ones with no tiles in the bbox, and joins several with `pmtiles merge`. A dry-run output it cannot parse fails the step instead of counting as zero tiles. When the step ends, also on failure, it removes the part files of completed extracts and the merge temp file; a partial file left by an extract that itself fails stays until the next run overwrites it.

### CI

`.github/workflows/pipeline.yml` runs on pushes to `main` and on pull requests, in both cases only when they touch `pipeline/`, `config/` or the workflow file, and on manual dispatch. Both jobs run on `ubuntu-24.04`, not `ubuntu-latest`: the tool pins, the cached binaries and the Boost 1.83 runtime package were verified on that image, so moving to another one is a deliberate change.

- `unit`: `ruff check`, `ruff format --check` and `pytest`, without the external tools.
- `smoke`: restores the tool binaries from a cache keyed by the pins, or runs `pipeline/bootstrap.sh` on a miss; runs `maqs check-tools`; builds the `test` region against the live archives; prints the report; uploads `dist/test` as the `test-region-fixtures` artifact (three files, about 3.1 MB, kept 7 days). The Swift tests (Phase 4) will download that artifact instead of committing binaries.

A cold run (cache miss, bootstrap about 2 min) takes about 3 min 15 s; a warm run takes about 1 min 20 s.

## Swift package

Phase 4. See `docs/BRIEF.md` and [ADR 0003](decisions.md): MapLibre on iOS and iPadOS only; `MaqsCore`, `MaqsData` and `MaqsTerrain` also build for macOS.
