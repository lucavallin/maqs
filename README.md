# maqs

Map data and a Swift package for native Apple apps: Shortbread basemap tiles, terrarium terrain, hiking trails, places and road curvature, per region. Online-first, offline optional, zero hosting cost: code in this repository, data as GitHub Release assets, compute in GitHub Actions. One map provider, [VersaTiles](https://versatiles.org), serves every tile online and offline.

**Status:** Phase 1 in progress. The pipeline builds the basemap, terrain and bundled base packs. The data layers, the release workflow and the Swift package come next. [`docs/BRIEF.md`](docs/BRIEF.md) has the plan and [`docs/decisions.md`](docs/decisions.md) has every decision and the numbers behind it.

## Build a region locally

```sh
pipeline/bootstrap.sh            # installs versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu 24.04)
cd pipeline && uv sync
uv run maqs check-tools
uv run maqs build --region test  # tiles and build-report.json in dist/test/ at the repository root
uv run maqs build --region veneto
uv run maqs regions
```

Outputs go to `dist/` at the repository root, even when you run from `pipeline/`; `--dist` overrides it. They are PMTiles archives, described in [`docs/data-format.md`](docs/data-format.md). Adding a region anywhere in the world is one entry in `config/regions.yaml`; [`docs/architecture.md`](docs/architecture.md) lists its fields.

## Develop

```sh
cd pipeline
uv run pytest -q                 # unit tests, no network
uv run pytest --run-network -q   # plus the live test-region build
uv run ruff check . && uv run ruff format .
```

## Licences

Code: Apache-2.0 ([`LICENSE`](LICENSE)). Data: OpenStreetMap under the ODbL, plus the attributions in [`DATA_LICENSE.md`](DATA_LICENSE.md).
