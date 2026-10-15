# Data formats

This document lists every file maqs publishes, with a version for each format. A format change bumps the version named in its section and states the compatibility rule. Today the pipeline builds the tile archives and the build report. The SQLite layers (trails, places, curvature) and the trail overlay tiles will be added here when the pipeline builds them.

## Tile archives (PMTiles v3)

Every tile output is a [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) archive with `tile_compression` and `internal_compression` each gzip or none. The archives `versatiles` writes (basemap, terrain, base packs) are clustered, with gzip internal compression. MapLibre Native reads gzip or uncompressed tiles only and rejects brotli and zstd, so the pipeline recompresses VersaTiles' brotli basemap tiles to gzip.

The tile archives carry no `layer_schema_version` yet. The per-layer version arrives with `manifest.json` in Phase 2.

| File | Layer | Tile type | Zoom | Tile compression | Source and extent |
|---|---|---|---|---|---|
| `<region>-basemap.pmtiles` | basemap | MVT, Shortbread 1.0 (OSM plus ESA WorldCover landcover) | 0–14 | gzip | `download.versatiles.org/osm-landcover.versatiles`: the region's bbox plus a ring of `bbox_border` tiles at every zoom (default 1, 0 for `test`) |
| `<region>-terrain.pmtiles` | terrain | WebP 512 px, terrarium-encoded DEM | 0–12 | none | `download.versatiles.org/elevation.versatiles` (Mapterhorn's build), same bbox and border as the basemap |
| `<region>-terrain-hd.pmtiles` | terrain-hd (opt-in) | terrarium, as Mapterhorn stores it (WebP or PNG accepted) | 13–`hd_max_zoom` (13 by default) | gzip or none | `download.mapterhorn.com/6-<x>-<y>.pmtiles`, the region's bbox, merged into one archive when the bbox spans several; no border |
| `base-<pack>-basemap.pmtiles` | base pack, bundled inside apps | MVT, Shortbread 1.0 | 0–`max_zoom` (10 by default) | gzip | as the basemap, over the union bbox of the pack's regions; no border |

Region outputs are written to `dist/<region>/`, base packs to `dist/base/`.

Terrarium decoding: `elevation_m = (R * 256 + G + B / 256) - 32768`. The tiles are 512 px, so at zoom 12 one pixel is about 13 m at 46° N (a z12 tile is about 6.8 km wide there).

The archive metadata is a JSON object. Basemap archives carry `tile_schema: "shortbread@1.0"`, terrain archives `tile_schema: "dem/terrarium"` and `tile_size: 512`. Both carry the upstream `attribution` string. The basemap also carries `planetiler:osm:osmosisreplicationtime`, the date of the OSM data in the VersaTiles build, which the build report copies out as `source_data_date`. The terrain archive has no date key, so terrain's `source_data_date` is null. `versatiles probe` shows the metadata; the pipeline reads it with its own header reader (`pipeline/src/maqs/pmtiles_header.py`).

Measured sizes per region are in [`docs/decisions.md`](decisions.md), ADR 0009.

## Build report (`build-report.json`, `report_version` 1)

Every run writes `dist/<region>/build-report.json`, or `dist/base/build-report.json` for the base packs, also when a step fails.

| Field | Meaning |
|---|---|
| `report_version` | 1 |
| `region` | the region id, or `base-<pack>` |
| `built_at` | ISO 8601 UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `tools` | tool name → version found (`dev` for the Homebrew `pmtiles` build) |
| `steps[]` | `name`, `status` (`built`, `skipped` or `failed`), `seconds`, `command` (argv; empty when skipped), `outputs[]`, and `error` when failed |
| `steps[].outputs[]` | `file`, `bytes`, `sha256`, `tile_type`, `min_zoom`, `max_zoom`, `tiles`, `compression`, `attribution`, `source_data_date` (both null when the archive metadata has no value) |
| `validation` | `ok`, and `failures`: a list of `<step>: <message>` |

Compatibility rule: readers ignore unknown fields. A new `report_version` means a field changed meaning or was removed.

## Validation rules

Every output, including the outputs of a step skipped because they already exist:

- smaller than 1.9 GiB (`1.9 × 2^30` bytes);
- a readable PMTiles v3 header, and every section (root directory, metadata, leaf directories, tile data) ends within the file, so a tail-truncated archive is rejected;
- tile compression gzip or none, internal compression gzip or none;
- metadata that parses as a JSON object; gzip-compressed metadata may inflate to at most 8 MiB, and uncompressed metadata is bounded by the file size;
- the zoom range exactly as the layer specifies;
- the tile type the layer allows: MVT or MLT for the basemap and base packs, WebP or PNG for the terrain layers;
- at least one tile;
- its SHA-256 recorded.

Base packs must also be under 15 MB (15,000,000 bytes). For every `fixture: true` region (today `test`) the build prints a warning when its basemap plus terrain exceed 5,000,000 bytes. A failed check fails the step, and the build exits non-zero.
