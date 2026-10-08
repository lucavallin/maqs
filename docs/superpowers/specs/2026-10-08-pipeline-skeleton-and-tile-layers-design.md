# Pipeline skeleton and tile layers (Phase 1, plan 1)

**Date:** 2026-10-08 · **Status:** approved design, awaiting implementation plan · **Depends on:** `docs/BRIEF.md` (amended), ADRs 0001, 0003–0008.

## Goal

A Python pipeline that builds, validates and reports the two tile layers (basemap, terrain), the optional high-resolution terrain layer, and the bundled base pack for any region in `config/regions.yaml`, identically on a developer Mac and on `ubuntu-latest`. It is the skeleton the data layers (plan 2: trails, places, curvature) plug into. Everything comes from one map provider, VersaTiles (ADR 0004), through one CLI, `versatiles`; `pmtiles` is used only for the high-resolution terrain archives VersaTiles does not host.

Out of scope for this plan: trails, places, curvature, overlay tiles, the geometry-encoding ADR, `manifest.json` and `sources.json` (Phase 2), the GitHub Actions release workflow (Phase 3). The CI pieces built here are the test-region smoke build and the fixture hand-off to the Swift tests.

## Success criteria

- `uv run maqs build --region test` produces `dist/test/test-basemap.pmtiles` and `dist/test/test-terrain.pmtiles`, validated and reported, in **under 5 minutes** locally and in CI, from a clean checkout after `pipeline/bootstrap.sh`.
- `uv run maqs build --region veneto --layers basemap,terrain` reproduces the Phase 0 numbers within reason (basemap ≈ 240 MB and ≈ 19,000 tiles at z0–14; terrain ≈ 105 MB and ≈ 1,300 tiles at z0–12).
- `uv run maqs build --region base` produces the base pack (basemap z0–10 over the union bbox) under 15 MB (ADR 0008).
- `uv run maqs build --region triveneto` produces the combined pack; its basemap and terrain sizes are recorded in the report and in ADR 0009 (measured on 2026-10-08, numbers filled in by plan 1).
- A second run with nothing changed does no work; `--force` rebuilds.
- Every output is under 1.9 GiB or the build fails.
- `uv run pytest` and `uv run ruff check` are green; the step logic is unit-tested without the network.
- `docs/data-format.md` describes the tile outputs and the build report; `docs/architecture.md` describes the pipeline.

## Layout

```
pipeline/
├── pyproject.toml          # package "maqs", console script "maqs", deps: click, pyyaml; dev: pytest, ruff
├── uv.lock
├── bootstrap.sh            # installs pinned CLIs on macOS and Ubuntu; --check prints versions
├── src/maqs/
│   ├── __init__.py
│   ├── cli.py              # click commands: build, regions, check-tools
│   ├── config.py           # loads and validates config/regions.yaml, computes the base bbox
│   ├── context.py          # BuildContext: region, paths, tool versions, logger, force flag
│   ├── tools.py            # run(): logs the exact command, pins binaries, raises on non-zero exit; version probes
│   ├── cache.py            # .cache/ helpers: path for a URL, atomic writes
│   ├── steps/
│   │   ├── base.py         # Step protocol: name, outputs(ctx), build(ctx); skip rule
│   │   ├── basemap.py      # versatiles convert from osm-landcover.versatiles
│   │   ├── terrain.py      # versatiles convert from elevation.versatiles
│   │   ├── terrain_hd.py   # pmtiles extract + merge from Mapterhorn z6 archives
│   │   └── basepack.py     # basemap z0–10 over the union bbox
│   ├── validate.py         # size cap, probe-based tile counts, SHA-256
│   └── report.py           # build-report.json writer
└── tests/
    ├── test_config.py, test_steps.py, test_validate.py, test_report.py, test_tools.py
    └── fixtures/           # tiny hand-made files only (a few kB): a valid 1-tile PMTiles, a truncated one
```

`config/regions.yaml` (repo root, shared with Phase 2 and the workflows):

```yaml
schema_version: 1
base:
  max_zoom: 10            # the bundled pack: basemap only, union bbox of all regions
regions:
  - id: test
    name: { it: Nevegal (test), en: Nevegal (test) }
    bbox: [12.21, 46.08, 12.29, 46.13]     # tuned in plan 1 so basemap+terrain stay under ~5 MB
    fixture: true                          # built for tests and CI only; never listed to apps, never released
  - id: triveneto
    name: { it: Triveneto, en: Triveneto }
    bbox: [10.3818, 44.7923, 13.9187, 47.0921]   # union of the three regions below: one download for all of them
  - id: veneto
    name: { it: Veneto, en: Veneto }
    bbox: [10.6231, 44.7923, 13.1021, 46.6806]
  - id: friuli-venezia-giulia
    name: { it: Friuli-Venezia Giulia, en: Friuli-Venezia Giulia }
    bbox: [12.3214, 45.5809, 13.9187, 46.6480]
  - id: trentino-alto-adige
    name: { it: Trentino-Alto Adige/Südtirol, en: Trentino-South Tyrol }
    bbox: [10.3818, 45.6729, 12.4780, 47.0921]
```

Region ids are lowercase kebab-case and never change once released. **A region is the smallest unit a pack is cut at** (owner rule, 2026-10-08): there are no sub-region packs, and the `test` region is a fixture, excluded from the base pack's union bbox and from anything an app can list or download. Because tile extracts are bbox-based and the three regional bboxes overlap heavily, `triveneto` exists as a first-class region so a user who wants Veneto, Trentino-Alto Adige and Friuli together downloads one pack, not three overlapping ones; the single regions stay for users who want less. Plan 2 cuts the data layers by admin polygon, and for `triveneto` by the union of the three polygons. `trails.sources` per region is added by plan 2.

## CLI

```
maqs build --region <id>|all|base [--layers basemap,terrain,terrain-hd] [--force] [--dist DIR] [--cache DIR]
maqs regions                      # prints ids, names, bboxes, and the computed base bbox
maqs check-tools                  # prints each pinned CLI's version; non-zero exit on mismatch or missing tool
```

Defaults: layers `basemap,terrain` (terrain-hd is opt-in, both here and for apps), `--dist dist/`, `--cache .cache/`, both gitignored. `--region all` builds every region except `base`; `--region base` builds only the base pack. Exit code is non-zero on any step or validation failure; the report is still written for the steps that ran.

## Steps and idempotency

A `Step` has a `name`, `outputs(ctx) -> list[Path]`, and `build(ctx) -> None`. The runner skips a step when every output exists and `--force` is not set, logging "skipped: outputs present". There is no content-hash cache in plan 1: CI always starts from a clean checkout, and locally `--force` is the answer to "I changed the config". Each step writes to a temporary file in `dist/<region>/` and renames into place on success (`versatiles` 5 already does this for its own outputs; the merge step does it explicitly), so a crashed build never leaves a half-written output that the skip rule would trust.

`tools.run(argv, *, cwd=None)` is the only way the pipeline executes a CLI. It logs the exact command line at INFO, streams the tool's stderr to our log, pins the binary to the path found at startup, and raises `ToolError(returncode, stderr_tail)` on non-zero exit. No `shell=True`, no string interpolation into commands.

Downloads (plan 1 has only the Mapterhorn archives, which are read remotely and never downloaded whole) go through `cache.py`, keyed by a URL hash, written atomically. The VersaTiles extracts are remote range-request reads and produce outputs directly.

## Tile steps

| Step | Source | Command | Output |
|---|---|---|---|
| `basemap` | `https://download.versatiles.org/osm-landcover.versatiles` | `versatiles convert --bbox <bbox> --bbox-border 1 --compress gzip <src> <out>` | `<region>-basemap.pmtiles`, z0–14 |
| `terrain` | `https://download.versatiles.org/elevation.versatiles` | `versatiles convert --bbox <bbox> --bbox-border 1 --max-zoom 12 <src> <out>` | `<region>-terrain.pmtiles`, z0–12, WebP terrarium |
| `terrain-hd` | `https://download.mapterhorn.com/<z>-<x>-<y>.pmtiles` for every z6 tile intersecting the bbox | `pmtiles extract <archive> <part> --bbox=<bbox> --minzoom=13 --maxzoom=<hd_max_zoom>`, then `pmtiles merge <parts…> <out>` when more than one | `<region>-terrain-hd.pmtiles`, z13–13 by default |
| `base` | same as `basemap` | `versatiles convert --bbox <union> --max-zoom 10 --compress gzip <src> <out>` | `base-basemap.pmtiles`, z0–10, no border |

`--bbox-border 1` adds one ring of tiles around the region at every zoom so the map is not blank at the region edge; the base pack has no border. gzip is mandatory for the basemap (MapLibre rejects brotli, ADR 0001); the elevation archive is already uncompressed WebP and is left as is. `terrain-hd`'s max zoom is `hd_max_zoom: 13` in `regions.yaml`'s top level, overridable per region; z14 for Veneto is about 1 GB and stays opt-in by config, never the default. The `pmtiles merge` output must be clustered and gzip- or none-compressed; validation checks it like any other output.

Attribution and source dates: `versatiles convert` carries the source archive's metadata (attribution, OSM timestamp) into the output; the report copies them out via `versatiles probe` so Phase 2's manifest can read them from the report instead of the archives.

## Validation

Runs after every step, on the step's outputs:

1. **Size cap:** fail if any file is ≥ 1.9 GiB (`1.9 * 2**30` bytes). Hard failure, no override.
2. **Probe:** `versatiles probe <file>` must succeed; record tile type, zoom range, tile count, compression, and metadata. Fail if the compression is neither gzip nor none, if the zoom range is not what the step asked for, or if the tile count is zero.
3. **Checksum:** SHA-256 of each output, streamed, recorded in the report.
4. **Base pack budget:** fail if `base-basemap.pmtiles` exceeds 15 MB (ADR 0008); report the test region's basemap + terrain total so the bbox can be tuned, warn above 5 MB.

Validation failures fail the build and are listed in the report.

## Build report

`dist/<region>/build-report.json`, one per region, rewritten on every run:

```json
{
  "report_version": 1,
  "region": "test",
  "built_at": "2026-10-08T14:02:11Z",
  "tools": { "versatiles": "5.0.0", "pmtiles": "1.31.2" },
  "steps": [
    {
      "name": "basemap", "status": "built|skipped|failed", "seconds": 7.7,
      "command": ["versatiles", "convert", "..."],
      "outputs": [{
        "file": "test-basemap.pmtiles", "bytes": 1150240, "sha256": "…",
        "tile_type": "mvt", "min_zoom": 0, "max_zoom": 14, "tiles": 26, "compression": "gzip",
        "source": "https://download.versatiles.org/osm-landcover.versatiles",
        "source_data_date": "2026-06-07T23:59:58Z", "attribution": "…"
      }]
    }
  ],
  "validation": { "ok": true, "failures": [] }
}
```

Phase 2 builds the manifest from these reports; plan 2 adds row counts and anomaly lists to the same structure.

## Test region and fixtures

The `test` bbox grows from the Phase 0 probe (~10 km², three trails) to about 12.21,46.08,12.29,46.13 (~35 km² around Nevegal), then is tuned so `test-basemap.pmtiles` + `test-terrain.pmtiles` stay under about 5 MB while covering more than a handful of trails for plan 2. The final numbers are recorded in `regions.yaml` and the report.

Pipeline outputs are **never committed**. The Swift tests get their fixtures from a build: locally, `uv run maqs build --region test` first; in CI, `swift.yml` runs an Ubuntu job that bootstraps and builds the test region (well under a minute for the two tile layers) and uploads `dist/test/` as an artifact that the macOS test job downloads. Only tiny hand-made files for corrupt-input tests live in git, under `pipeline/tests/fixtures/` and later `Tests/Fixtures/`.

## Bootstrap

`pipeline/bootstrap.sh` (POSIX sh, `set -eu`) installs the pinned tools and prints their versions; `--check` only verifies. Pins live at the top of the script and are the single source of truth the Python version probe compares against.

| Tool | Pin | macOS | Ubuntu 24.04 |
|---|---|---|---|
| versatiles | 5.0.0 | `brew tap versatiles-org/versatiles && brew install versatiles` | `.deb` from the GitHub release for the runner's arch |
| pmtiles | 1.31.2 | `brew install pmtiles` | release tarball `go-pmtiles_<v>_Linux_<arch>.tar.gz` |
| osmium-tool | 1.19.1 | `brew install osmium-tool` | built from source (apt has 1.16); cached in CI by version |
| tippecanoe | 2.79.0 | `brew install tippecanoe` | built from source (apt has 2.49); cached in CI by version |
| uv | current | assumed present (`astral-sh/setup-uv` in CI) | same |

osmium-tool and tippecanoe are installed now even though plan 2 is their first user, so the script and its CI cache are proven once. `maqs check-tools` fails on a version mismatch rather than warning: a different `versatiles` can change tile compression or metadata silently.

## Tests

- `test_config.py`: loads the real `regions.yaml`; rejects a bad bbox, a duplicate id, a non-kebab id; computes the union bbox excluding `test`.
- `test_steps.py`: each step's `outputs()` and the exact argv it builds, with `tools.run` stubbed; the skip rule (outputs present, `--force`); the terrain-hd z6-tile enumeration for a bbox that spans two archives.
- `test_validate.py`: size cap at the boundary; probe parsing from a captured `versatiles probe` text; rejection of brotli; SHA-256 of a known file.
- `test_report.py`: the report shape and that failures are recorded.
- `test_tools.py`: `run()` raises `ToolError` with the stderr tail; never uses a shell.
- One integration test, marked `network`, skipped by default and run in CI: builds the test region and checks the report.

Deterministic: no network in unit tests, no sleeps, temp dirs per test.

## Documentation

- `docs/data-format.md` (new, versioned): the PMTiles outputs (tile types, zoom ranges, compression, metadata fields), the base pack, `terrain-hd`, and the build report schema (`report_version: 1`).
- `docs/architecture.md` (new): the pipeline's step model, idempotency rule, directories, tool pins, and how CI hands fixtures to the Swift tests.
- `README.md` (new, minimal): what maqs is, how to run the test build, links to the docs and the licences. `DATA_LICENSE.md` (new): ODbL notice plus the OpenStreetMap, ESA WorldCover and Mapterhorn attribution strings verified in Phase 0.
- `docs/decisions.md`: ADR 0009 for the region-as-smallest-unit rule, the `triveneto` combined region with its measured sizes, the test-region bbox and the fixture hand-off (short).

## Risks

- **tiles.versatiles.org/download.versatiles.org availability.** A build that cannot reach the download server fails loudly; there is no fallback and none is planned (ADR 0004).
- **`pmtiles merge` behaviour** across several Mapterhorn archives is verified in plan 1 on a bbox that spans two z6 tiles; if merge output is not clustered or not gzip/none, the step falls back to a single-archive restriction and an ADR records it.
- **Ubuntu source builds** of osmium-tool and tippecanoe add minutes to a cold CI run; the cache keyed by version makes it a one-time cost per pin.
