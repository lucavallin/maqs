# Bootstrap `maqs`

You are setting up `maqs`, a **public** GitHub repository that provides map data and a Swift package for a small family of native Apple apps (iOS/iPadOS/macOS). The apps live in a separate private repo and depend on this one. This repo must never reference them: it's generic, reusable plumbing.

Read this whole brief before doing anything. Then work through the phases in order, committing at the end of each one.

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

1. **Basemap: Shortbread vector tile schema.**
   - Online primary: VersaTiles public server (tiles.versatiles.org).
   - Online fallback: OSMF vector tiles (vector.openstreetmap.org), which serve the same schema. OSMF's usage policy forbids bulk downloads, requires a real app-identifying User-Agent, forbids no-cache headers, and requires local caching. Comply with all of it.
   - Offline: `versatiles convert --bbox ... https://download.versatiles.org/osm.versatiles region.pmtiles`. This is a remote range-request extract, so never download the planet.
   - Pin the Shortbread schema version and record it in the manifest.
2. **Terrain: terrarium-encoded DEM.**
   - Online: AWS Open Data terrain tiles (terrarium). Verify the current URL and terms.
   - Offline: `pmtiles extract` from the Protomaps terrarium PMTiles build (was "terrarium-z12.pmtiles (preview)"). Verify the URL, max zoom, stability and attribution requirements (Joerd/Mapzen sources).
   - Online and offline must use the same encoding so the Swift DEM sampler has one code path.
3. **OSM source data: Geofabrik `europe/italy/nord-est` PBF.** Download it once per run, then `osmium extract` per region.
4. **Trails:** OSM `route=hiking` relations, keeping these tags: `ref`, `ref:REI`, `name`, `cai_scale`, `network`, `operator`, `osmc:symbol`, `from`, `to`, `roundtrip`, `survey:date`, `website`.
   - Italian trails are maintained under the CAI–Wikimedia Italia agreement (see the OSM wiki page "CAI" and the OSM2CAI project).
   - Look at `github.com/osmItalia/cai_scripts` (`caiosm`) and reuse it if it fits. Otherwise use `osmium tags-filter` plus `osmium export`.
5. **Places:**
   - `natural=peak`, `natural=volcano`, `natural=saddle`, `mountain_pass=yes`
   - `tourism=alpine_hut`, `tourism=wilderness_hut`, `amenity=shelter`
   - named villages and hamlets (`place=village|hamlet|isolated_dwelling`)
   - Keep `name`, `name:it`, `name:de`, `name:fur`, `name:sl`, `ele`, `wikidata`.
   - Compute a `rank_score` for label priority: a `wikidata` tag counts as a strong notability signal, combined with elevation. Keep the formula simple and documented.
6. **Road curvature:**
   - Use Adam Franco's `curvature` project (github.com/adamfranco/curvature) on the region PBF for per-segment curvature scores. Verify its license and that it still runs. Running a GPL tool in the pipeline is fine; we only distribute its output data.
   - Additionally derive a `corners` table: discrete curves with apex position, minimum radius (three-point circle method over the way geometry), direction (left/right), and entry/exit positions.
   - If `curvature` is unusable, implement the minimal equivalent in Python and document why.
7. **Distribution:** per-region files plus a `manifest.json` in a GitHub Release tagged `data-YYYY-MM`, marked as latest. Clients fetch `https://github.com/<owner>/maqs/releases/latest/download/manifest.json`. **Never use the GitHub REST API from clients** (60 req/h unauthenticated limit).
8. **Rendering:** MapLibre Native iOS via SPM, reading local PMTiles with `pmtiles://file://...` (supported since 6.10; verify current version). PMTiles sources don't support MapLibre offline packs or ambient caching, so offline means our own downloaded PMTiles, not MapLibre offline packs.

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
- **Tools:** external CLIs (`versatiles`, `pmtiles`, `osmium`, `tippecanoe`, `curvature`) get installed by a `pipeline/bootstrap.sh` that works on macOS and Ubuntu, with pinned versions.
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
- **`swift.yml`:** build and test the package on macOS runners for iOS Simulator and macOS, using the `test` region fixtures.
- Initial regions in `regions.yaml`: `veneto`, `friuli-venezia-giulia`, `trentino-alto-adige`, `test`. Adding a region means adding one entry, nothing else.

## Phase 4: Swift package `Maqs`

- **Platform and build:** Swift 6 language mode with strict concurrency, iOS 18+ and macOS 15+. Public API documented with DocC comments.
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
  - Same API whether data comes from a local pack or online tiles, with an in-memory LRU cache for online tiles.
- **MaqsUI:**
  - SwiftUI map view wrapping MapLibre Native.
  - Builds the style at runtime from: a style JSON passed in by the app (the package ships only a plain default style, since apps bring their own look), online sources from `sources.json`, and local PMTiles when a covering region is installed.
  - **Requirement:** in an installed region the map works fully with no network; outside installed regions it streams online. Design the switching strategy (e.g. prefer local PMTiles for installed bboxes, online elsewhere, react to `NWPathMonitor`) and record it as an ADR.
  - Overlay helpers to add trails and places layers.
  - An attribution view that always shows the correct required credits for the active sources.
  - Set an app-identifying User-Agent on MapLibre's network configuration (OSMF requirement); never send no-cache headers.
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
