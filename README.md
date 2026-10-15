# maqs

Map data and a Swift package for native Apple apps: Shortbread basemap tiles, terrarium terrain, hiking trails, places and road curvature, per region. Online-first, offline optional, zero hosting cost: code in this repository, data as GitHub Release assets, compute in GitHub Actions. One map provider, [VersaTiles](https://versatiles.org), serves every tile online and offline.

**Status:** Phase 1 in progress. The pipeline builds all five layers of a region (basemap, terrain, trails, places, curvature) and the bundled base packs. The manifest, the release workflow and the Swift package come next. [`docs/BRIEF.md`](docs/BRIEF.md) has the plan and [`docs/decisions.md`](docs/decisions.md) has every decision and the numbers behind it.

## Build a region locally

```sh
pipeline/bootstrap.sh            # installs versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu 24.04)
cd pipeline && uv sync
uv run maqs check-tools
uv run maqs build --region test  # all five layers and build-report.json in dist/test/ at the repository root
uv run maqs build --region veneto
uv run maqs build --region veneto --layers basemap,terrain  # only some layers
uv run maqs regions
```

Outputs go to `dist/<region>/` at the repository root, even when you run from `pipeline/`; `--dist` overrides it. A full build writes `<region>-basemap.pmtiles`, `<region>-terrain.pmtiles`, `<region>-trails.sqlite`, `<region>-trails.pmtiles`, `<region>-places.sqlite`, `<region>-places.pmtiles`, `<region>-curvature.sqlite` and `build-report.json`, all described in [`docs/data-format.md`](docs/data-format.md). The trails, places and curvature layers read the region's Geofabrik extract (about 625 MB for `europe/italy/nord-est` in October 2026), downloaded once into `.cache/` and reused; delete it to get a fresh one. Adding a region anywhere in the world is one entry in `config/regions.yaml`; [`docs/architecture.md`](docs/architecture.md) lists its fields.

## Develop

```sh
cd pipeline
uv run pytest -q                 # unit tests, no network
uv run pytest --run-network -q   # plus the live test-region build; downloads the Geofabrik extract into .cache/ once
uv run ruff check . && uv run ruff format .
```

## Licences

Code: Apache-2.0 ([`LICENSE`](LICENSE)). Data: OpenStreetMap under the ODbL, plus the attributions in [`DATA_LICENSE.md`](DATA_LICENSE.md).
