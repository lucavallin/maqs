# maqs

Map data and a Swift package for native Apple apps: Shortbread basemap tiles, terrarium terrain, hiking trails, places and road curvature, per region. Online-first, offline optional, zero hosting cost: code in this repository, data as GitHub Release assets, compute in GitHub Actions. One map provider, [VersaTiles](https://versatiles.org), serves every tile online and offline.

**Status:** the pipeline builds all five layers of a region (basemap, terrain, trails, places, curvature) and the bundled base packs, and writes `manifest.json` from the build reports. A GitHub Actions workflow builds every region each month and publishes the files as a release. The Swift package comes next. [`docs/BRIEF.md`](docs/BRIEF.md) has the plan and [`docs/decisions.md`](docs/decisions.md) has every decision and the numbers behind it.

## Data releases

A GitHub Actions workflow, [`build-maps.yml`](.github/workflows/build-maps.yml), builds every region at 03:00 UTC on the 1st of each month and publishes a GitHub Release tagged `data-YYYY-MM`, marked latest. Each release holds a `manifest.json`, the base pack files, and the files of every region in `config/regions.yaml` except the `test` fixture. The first release has not been published yet. Clients will read `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json`, which lists each file with its size, its SHA-256 and a URL pinned to its release. The online tile sources are in [`config/sources.json`](config/sources.json), which clients will read from `main`. A client picks the files it can read by the [compatibility rule](docs/data-format.md#compatibility-rule).

To run the workflow by hand, for example after a failed month:

```sh
gh workflow run build-maps.yml                 # every region and the base packs; publishes this month's release
gh workflow run build-maps.yml -f region=test  # one region (or base): builds it and uploads the dist-test artifact; publishes nothing
```

A run in a month that already has a release replaces that release's files in place, the manifest last. It never touches an older release, and when it succeeds every file the new manifest names is there. A dispatch with `-f region=…` or `-f layers=…` only builds, and keeps its outputs as workflow artifacts for 7 days. [`docs/architecture.md`](docs/architecture.md#data-releases) explains the jobs, and ADR 0013 in [`docs/decisions.md`](docs/decisions.md) gives the reasons.

## Build a region locally

```sh
pipeline/bootstrap.sh            # installs versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu 24.04)
cd pipeline && uv sync
uv run maqs check-tools
uv run maqs build --region test  # all five layers and build-report.json in dist/test/ at the repository root
uv run maqs build --region veneto
uv run maqs build --region veneto --layers basemap,terrain  # only some layers
uv run maqs build --region base  # the base packs, in dist/base/
uv run maqs regions
```

Outputs go to `dist/<region>/` at the repository root, even when you run from `pipeline/`; `--dist` overrides it. A full build writes `<region>-basemap.v1.pmtiles`, `<region>-terrain.v1.pmtiles`, `<region>-trails.v1.sqlite`, `<region>-trails.v1.pmtiles`, `<region>-places.v1.sqlite`, `<region>-places.v1.pmtiles`, `<region>-curvature.v1.sqlite` and `build-report.json`, all described in [`docs/data-format.md`](docs/data-format.md). The `.v1` is the layer's schema version. The trails, places and curvature layers read the region's Geofabrik extract (about 625 MB for `europe/italy/nord-est` in October 2026), downloaded once into `.cache/` and reused; delete it to get a fresh one. Adding a region anywhere in the world is one entry in `config/regions.yaml` when the region is cut from the `europe/italy/nord-est` extract; a region from another Geofabrik extract also needs an edit to `.github/workflows/build-maps.yml` (ADR 0013). [`docs/architecture.md`](docs/architecture.md) lists the fields.

## Develop

```sh
cd pipeline
uv run pytest -q                 # unit tests, no network
uv run pytest --run-network -q   # plus the live test-region build; downloads the Geofabrik extract into .cache/ once
uv run ruff check . && uv run ruff format .
uv run maqs check-config         # regions.yaml, and sources.json against its schema
uv run maqs manifest --release data-ci --regions test  # dist/manifest.json from the test and base builds; data-ci is never published
```

## Licences

Code: Apache-2.0 ([`LICENSE`](LICENSE)). Data: OpenStreetMap under the ODbL, plus the attributions in [`DATA_LICENSE.md`](DATA_LICENSE.md).
