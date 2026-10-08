# Bootstrap `maqs`

You are setting up `maqs`, a **public** GitHub repository that provides map data and a Swift package for a small family of native Apple apps (iOS/iPadOS; the data and terrain modules also build for macOS, the map view does not). The apps live in a separate private repo and depend on this one. This repo must never reference them: it's generic, reusable plumbing.

Read this whole brief before doing anything. Then work through the phases in order, committing at the end of each one.

> **Amended 2026-10-07 after Phase 0** (see `decisions.md`, ADRs 0001–0006). The owner's standing rules, which override anything older below: **one map provider for online and offline** (VersaTiles); **as few providers as possible**; **no unmaintained or stale tools or datasets** — if something is dormant, replace it or write the small equivalent ourselves; **trail data must be fetchable from more than one source** because Italian trail stewardship is fragmented (CAI, Alpenverein Südtirol, SAT, regional networks).

## Goals and hard constraints

- **Online-first, offline optional.** With a connection, apps stream maps from free public sources and need no downloads. Offline region packs are an opt-in download.
- **Zero hosting cost.** No paid services, no cloud buckets, no servers. Everything lives on GitHub: code in the repo, data as **GitHub Release assets**, compute in **GitHub Actions** (unlimited on public repos).
- **Reuse, don't build.** Never render tiles from scratch. Cut regions from existing prebuilt sources and filter OSM data with existing tools. Write custom code only where no tool exists.
- **No Git LFS** (tiny free bandwidth quota). Build outputs never get committed to git; they go to Releases only.
- **Release assets must be under 2 GiB each.** Enforce a hard limit of 1.9 GiB in CI and fail the build above it.
- **Swift package dependencies:** MapLibre Native is the only allowed third-party dependency. Use system frameworks for everything else (SQLite3, Compression, CryptoKit, Network, URLSession).
- **No provider URL hardcoded in Swift logic.** Online sources come from `config/sources.json` (fetched from `main`, cached, with a bundled copy as fallback), so a provider can be swapped without an app update.

## Decisions already made (don't relitigate; verify facts)

These were chosen after research. Treat them as fixed. In Phase 0, verify that every URL, license, version, size and capability below is still true. If something has changed or is wrong, stop and report before building on it.

1. **Basemap: Shortbread vector tile schema, VersaTiles only** (ADR 0004).
   - Online: the VersaTiles public server, `https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}` (TileJSON at `/tiles/osm/tiles.json`). It is a demo server with no SLA and a per-IP rate limit; honour its six-hour `Cache-Control`, send an app-identifying User-Agent, never send no-cache headers.
   - Offline: `versatiles convert --bbox … --compress gzip https://download.versatiles.org/osm-landcover.versatiles region.pmtiles`. A remote range-request extract, never a planet download. **gzip is mandatory**: MapLibre Native reads PMTiles with gzip or no compression only, and VersaTiles writes brotli by default. The landcover variant is used so offline tiles match the hosted ones byte for byte.
   - Schema pinned to **Shortbread 1.0** (what VersaTiles serves), recorded in the manifest. No second basemap provider; `sources.json` can add one later without an app update.
   - Attribution: `© OpenStreetMap contributors` (ODbL) and `CC BY 4.0 ESA WorldCover 2021` (the landcover layers).
2. **Terrain: terrarium-encoded DEM, VersaTiles only** (ADR 0004).
   - Online: `https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}` — the Mapterhorn build repackaged by VersaTiles: 512 px WebP, terrarium, zoom 0–12.
   - Offline: `versatiles convert --bbox … https://download.versatiles.org/elevation.versatiles region.pmtiles` (tiles are already uncompressed WebP; no recompression needed).
   - Same provider, same encoding, same tiles online and offline, so the Swift DEM sampler has one code path. Decoding goes through ImageIO (WebP is supported since iOS 14).
   - Attribution: `© Mapterhorn` plus the per-source credits from `https://download.mapterhorn.com/attribution.json` for sources intersecting our regions.
3. **OSM source data: Geofabrik extracts, one per region as configured.** Each region in `config/regions.yaml` names its Geofabrik extract (`europe/italy/nord-est` for the launch regions); the pipeline downloads each distinct extract once per run, then cuts per region by admin polygon (OSM relation ids) or bbox. Nothing is Italy-specific: a region anywhere in the world is one config entry, and online tiles are worldwide already (amended 2026-10-08: one consuming app is Italy-only, others may need any part of the world).
4. **Trails: multi-source by design** (ADR 0006). Trail stewardship is fragmented: CAI in most of Italy, the Alpenverein Südtirol (AVS) in South Tyrol, SAT in Trentino, and regional networks. Phase 0 measured it: only 25 % of hiking relations in Trentino-Alto Adige carry `cai_scale`, against ~60 % in Veneto and Friuli.
   - Every source is an **adapter** that emits one normalised trail record (id, ref, name, difficulty on a normalised scale plus the original value, operator, network, symbol, geometry, provenance: `source`, `source_id`, `source_licence`, `source_date`). Everything downstream (ascent/descent, SQLite, overlay tiles) sees only that format.
   - `config/regions.yaml` lists the trail sources per region in priority order. Duplicates across sources are resolved by `ref` plus geometric overlap; the higher-priority source wins and the other is kept as a secondary reference.
   - **Adapter 1 (Phase 1): OSM** `route=hiking` relations from the Geofabrik extract, keeping `ref`, `ref:REI`, `name`, `cai_scale`, `sac_scale`, `network`, `operator`, `osmc:symbol`, `from`, `to`, `roundtrip`, `survey:date`, `website`. Geometry is assembled by our own small pyosmium step (merge and order member ways, flag gaps and reversals) from the **uncut** nord-est file, because `osmium export` does not assemble route relations and 5–10 % of relations cross region borders.
   - **Later adapters** are not needed for the first release; the architecture must accommodate them without rework. The first candidate is the Alpenverein Südtirol (AVS itself or the Province of Bolzano open data); then SAT/Trentino, the Veneto and Friuli-Venezia Giulia regional networks, OSM2CAI. Each gets a short source ADR (format, licence, attribution) before implementation. `osmItalia/cai_scripts` is not reused (dormant since 2021, Overpass-driven); only its tag conventions were consulted.
5. **Places:**
   - `natural=peak`, `natural=volcano`, `natural=saddle`, `mountain_pass=yes`
   - `tourism=alpine_hut`, `tourism=wilderness_hut`, `amenity=shelter`
   - named villages and hamlets (`place=village|hamlet|isolated_dwelling`)
   - Keep `name`, `name:it`, `name:de`, `name:fur`, `name:sl`, `ele`, `wikidata`.
   - Compute a `rank_score` for label priority: a `wikidata` tag counts as a strong notability signal, combined with elevation. Keep the formula simple and documented.
6. **Road curvature: our own small implementation** (ADR 0005). Adam Franco's `curvature` was evaluated in Phase 0: it runs on Python 3.12 only with two dependency pins, is GPLv3 with no LICENSE file, and has had no commit since 2022. We do not depend on dormant tools.
   - Per way: split into segments between consecutive nodes, compute each segment's radius with the three-point circle method, classify by radius bands, and sum a curvature score per way the way `curvature` does (documented in `data-format.md` so the numbers stay comparable).
   - Derive the `corners` table: discrete curves with apex position, minimum radius, direction (left/right), and entry/exit positions along the segment.
   - Highway classes and surface filters are configuration, not code.
7. **Distribution:** per-region files plus a `manifest.json` in a GitHub Release tagged `data-YYYY-MM`, marked as latest. Clients fetch `https://github.com/<owner>/maqs/releases/latest/download/manifest.json`. **Never use the GitHub REST API from clients** (60 req/h unauthenticated limit).
8. **Rendering: MapLibre Native iOS via SPM, iOS and iPadOS only** (ADR 0003). Pin `6.31.0` with an upper bound below `7.0.0`. Local PMTiles via `pmtiles://file://…` (since 6.10). Offline packs do not work with PMTiles sources (an ambient cache for remote PMTiles exists since 6.27), so offline means our own downloaded PMTiles. MapLibre's SwiftPM binary has no macOS slice; `MaqsUI` is declared for iOS only, while `MaqsCore`, `MaqsData` and `MaqsTerrain` also build for macOS so tests run on macOS runners. Hillshade from the terrain layer is available in MapLibre Native; 3D terrain is not.

## Repo layout (target)

```
maqs/
├── README.md                  # what this is, how to use the data and the package, licenses
├── CLAUDE.md                  # conventions and commands for future Claude Code sessions
├── LICENSE                    # Apache-2.0 for code
├── DATA_LICENSE.md            # ODbL notice + all attribution requirements for the data
├── Package.swift              # package "Maqs"
├── Sources/
│   ├── MaqsCore/              # manifest, sources.json, region catalog, downloads, storage
│   ├── MaqsData/              # SQLite readers: trails, places, curvature (FTS5 + R*Tree)
│   ├── MaqsTerrain/           # PMTiles v3 reader, terrarium decoding, DEM sampling
│   └── MaqsUI/                # MapLibre integration (only module importing MapLibre)
├── Tests/                     # one test target per module, with small fixtures
├── Examples/MaqsDemo/         # minimal SwiftUI app to eyeball everything
├── config/
│   ├── sources.json           # online tile sources, priority order
│   └── regions.yaml           # region id, display names (it/en), bbox
├── pipeline/                  # Python (uv-managed) orchestrator + per-layer steps
├── docs/
│   ├── decisions.md           # ADR log, starting with Phase 0 findings
│   ├── architecture.md
│   └── data-format.md         # every file format and SQLite schema, versioned
└── .github/workflows/
    ├── build-maps.yml         # data pipeline
    └── swift.yml              # package build + tests
```

The package exposes one product per module (`MaqsCore`, `MaqsData`, `MaqsTerrain`, `MaqsUI`) so apps import only what they need. For example, an app that only needs elevation sampling can depend on `MaqsTerrain` without pulling in MapLibre.

## Phase 0: Verify and record (stop after this phase)

- Verify every item under "Decisions already made":
  - current URLs and terms of use
  - licenses and exact attribution strings
  - tool versions and install methods on `ubuntu-latest` and macOS
  - whether the VersaTiles remote extract and `pmtiles extract` work as described
- Measure real numbers for the **Veneto** bbox: basemap size at max zoom, terrain size at z12, Geofabrik nord-est PBF size, and how long each step takes.
- Check that Apple's system SQLite on iOS 18 / macOS 15 has **FTS5** and **R*Tree** enabled. If not, report alternatives.
- Do a quick coverage check: how many `route=hiking` relations in Veneto, Friuli-Venezia Giulia and Trentino-Alto Adige carry `cai_scale` and `ref`. Report the counts per region.
- Write all findings to `docs/decisions.md` as short ADRs, flagging anything that contradicts the brief.
- **Then stop and give me a summary. Wait for my go-ahead before Phase 1.**

## Phase 1: Pipeline (runs locally and in CI)

- **Orchestration:** a Python package in `pipeline/` managed with `uv`. Entry point: `uv run maqs build --region veneto [--layers basemap,terrain,trails,places,curvature]`.
- **Tools:** external CLIs (`versatiles`, `osmium`, `tippecanoe`; `pmtiles` only for inspection) get installed by a `pipeline/bootstrap.sh` that works on macOS and Ubuntu, with pinned versions. Ubuntu's apt packages for osmium-tool and tippecanoe are old; the script fetches or builds current versions there.
- **Behavior:**
  - Steps are idempotent, cache downloads in `.cache/` (gitignored), and write outputs to `dist/<region>/` (gitignored).
  - A tiny `test` region (a few km², e.g. around Nevegal) runs end to end in under 5 minutes; CI and the Swift tests use it as fixtures.
- **Outputs per region:**

| File | Contents |
|---|---|
| `<region>-basemap.pmtiles` | Shortbread vector tiles |
| `<region>-terrain.pmtiles` | terrarium raster |
| `<region>-trails.sqlite` | trails index |
| `<region>-trails.pmtiles` | trails overlay vector tiles, built with tippecanoe |
| `<region>-places.sqlite` | places index |
| `<region>-places.pmtiles` | places overlay |
| `<region>-curvature.sqlite` | road segments and corners |

- **SQLite requirements**, documented precisely in `docs/data-format.md`:
  - Every DB has a `metadata` table: `schema_version`, `layer`, `region`, `data_date`, `osm_timestamp`, `attribution`.
  - Spatial lookups use R*Tree; text search uses FTS5 (unicode61 with `remove_diacritics`).
  - Geometries are stored compactly (encoded polyline or float32 blobs). Pick one, justify it in an ADR, and use it everywhere.
- **Schema per layer:**
  - **Trails:** relation id, the tags above, `length_m`, `ascent_m`/`descent_m` computed from our own terrain data, bbox, geometry (merged and ordered where possible; flag broken relations instead of failing).
  - **Places:** osm type and id, kind, the names, `ele`, `wikidata`, lat/lon, `rank_score`.
  - **Curvature:** segments (way ids, name, ref, highway class, surface, length, curvature score, geometry) and corners (segment id, apex lat/lon, min radius m, direction, entry/exit distance along segment).
- **Validation:** after each build, check sizes against the 1.9 GiB limit, sanity-check row counts against Phase 0 numbers, compute SHA-256 checksums, and generate a `build-report.json`.

## Phase 2: Manifest and config formats

- **`manifest.json`:**
  - `manifest_version`, `created_at`, `shortbread_version`
  - an `attribution` list
  - per region: `id`, names, bbox, and per layer: `file`, `url`, `bytes`, `sha256`, `layer_schema_version`
  - The manifest must let an old client find data it understands: a client with an older `layer_schema_version` must not break. Define and document that compatibility rule.
- **`sources.json`:** an ordered list of online providers per layer (basemap, terrain), each with tile URL template or TileJSON URL, schema, attribution, and max zoom.
- Write JSON Schemas for both in `config/schemas/` and validate against them in CI.

## Phase 3: GitHub Actions

- **`build-maps.yml`:**
  - Triggers: monthly cron, plus `workflow_dispatch` with optional `region` and `layers` inputs.
  - Jobs: one job downloads the Geofabrik PBF and shares it via artifact or cache; a matrix job per region (from `regions.yaml`) runs the build; a final job assembles `manifest.json`, creates the `data-YYYY-MM` release with `gh`, uploads all assets, and marks it latest.
  - Free disk space on the runner up front.
  - Pin action versions.
  - Make reruns safe: re-uploading the same month replaces assets.
- **`swift.yml`:** build and test the package on macOS runners: all products on the iOS Simulator, the three non-UI products on macOS, using the `test` region fixtures.
- Initial regions in `regions.yaml`: `triveneto` (the three below as one pack: a region is the smallest download unit, and the owner needs all three), `veneto`, `friuli-venezia-giulia`, `trentino-alto-adige`, and `test` (fixture only). Adding a region anywhere in the world means adding one entry, nothing else.

## Phase 4: Swift package `Maqs`

- **Platform and build:** Swift 6 language mode with strict concurrency. iOS 18+ for every product; `MaqsCore`, `MaqsData` and `MaqsTerrain` additionally macOS 15+ (so they test on macOS runners); `MaqsUI` is iOS-only. Public API documented with DocC comments.
- **MaqsCore:**
  - Manifest fetch with caching and ETag handling.
  - Region catalog.
  - The consuming app declares which layers it needs (e.g. `[.basemap, .curvature]`) and only those get downloaded.
  - Downloads: background `URLSession`, resumable, SHA-256 verified, atomic install into Application Support, excluded from iCloud backup.
  - Update check against the latest manifest.
  - Delete a region; report disk usage.
  - Install and download state observable from SwiftUI.
- **MaqsData:** async read-only query APIs over system SQLite3:
  - trails: FTS search by ref, name or difficulty; trails in bbox; trail by id
  - places: places along a bearing within a distance corridor (needed for line-of-sight apps); places in bbox
  - curvature: corners ahead of a position and heading along matched segments, keeping it a simple query API (map-matching itself is not this package's job)
  - Readers work for any installed region and fall back cleanly when none is installed.
- **MaqsTerrain:**
  - Minimal PMTiles v3 reader for local files (header, directories, varints, gzip via Compression).
  - Terrarium decoding: elevation = (R × 256 + G + B / 256) − 32768.
  - Bilinear elevation sampling at a coordinate.
  - Elevation profile along a great-circle line, with earth-curvature and standard refraction corrections exposed as parameters.
  - Decodes WebP and PNG tiles through ImageIO; accepts PMTiles tile types 2 (PNG), 4 (WebP) and, for vector archives, 1 and 6.
  - Same API whether data comes from a local pack or online tiles, with an in-memory LRU cache for online tiles.
- **MaqsUI:**
  - SwiftUI map view wrapping MapLibre Native.
  - Builds the style at runtime from: a style JSON passed in by the app (the package ships only a plain default style, since apps bring their own look), online sources from `sources.json`, and local PMTiles when a covering region is installed.
  - **Requirement:** in an installed region the map works fully with no network; outside installed regions it streams online. Design the switching strategy (e.g. prefer local PMTiles for installed bboxes, online elsewhere, react to `NWPathMonitor`) and record it as an ADR.
  - Overlay helpers to add trails and places layers.
  - An attribution view that always shows the correct required credits for the active sources.
  - Set an app-identifying User-Agent on MapLibre's network configuration and on every URLSession the package creates; never send no-cache headers; honour the provider's `Cache-Control`.
  - Glyphs and sprites must work offline: the package bundles a default glyph set (one open font family, regular and bold) and sprite, and styles reference local copies when offline.
- **Tests:** manifest and schema parsing, PMTiles reader against fixtures, terrarium decoding with known values, SQLite queries against `test` region fixtures, download verification (bad checksum gets rejected).
- **Demo:** `Examples/MaqsDemo` shows: online map, download the test region, airplane-mode map, trail search, places along a bearing, elevation profile.

## Working rules

- Keep custom code small. If a well-maintained tool already does something, call it instead of reimplementing it.
- Every non-obvious choice gets a short ADR in `docs/decisions.md`.
- Never commit generated data, credentials or tokens. CI uses only the default `GITHUB_TOKEN`.
- Make a commit per phase (or per meaningful chunk within one) with clear messages.
- If something in this brief turns out to be impossible, wrong, or clearly worse than an alternative, say so with evidence instead of silently working around it.
- End each phase with a short summary: what was built, what was verified, open questions.
