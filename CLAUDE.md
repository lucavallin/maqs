# CLAUDE.md

This file governs *how you work* in this repository. Section 1 and the Stack customization section at the end are project-specific; everything between is universal and applies to any language, platform, or stack. Rules marked `[ENFORCED: …]` are backed by a mechanical check in CI or pre-commit — that check, not this prose, is the guarantee. Everything else is the intent behind the checks; follow it as engineering judgment, not as a ritual.

---

## 1. Project context

### What this is
**maqs** is a public repository that provides **map data** and a **Swift package (`Maqs`)** for a small family of native Apple apps (iOS and iPadOS; the non-UI modules also build for macOS). The apps live in a separate private repository and depend on this one; this repo is generic, reusable plumbing and never references them. Online-first (apps stream tiles from free public sources), offline optional (per-region packs are an opt-in download). Zero hosting cost: code in git, data as GitHub Release assets, compute in GitHub Actions. Solo-maintained by Luca.

`docs/BRIEF.md` is the source of truth for *what* to build, in what order, and which decisions are already made; it was amended after Phase 0 and `docs/decisions.md` records why. The owner's standing rules sit at the top of the brief: one map provider online and offline, as few providers as possible, nothing unmaintained, trail data from more than one source. This file governs *how*. When the two disagree, say so; do not silently pick one.

**Where we are:** Phase 0 (verification) is done and recorded in `docs/decisions.md` ADRs 0001–0006. Phase 1 (pipeline) is next. The brief's phases are strictly ordered; each ends with a summary and waits for the go-ahead. Commands, paths, and file names below describe the contract the brief defines; a command that does not run yet is not a bug, it is a phase that has not happened.

### Explicitly out of scope
- Any reference to the consuming apps: their names, bundle ids, styles, or needs beyond what the public API expresses.
- Servers, buckets, CDNs, paid services, API keys for data providers, Git LFS, anything with a bill.
- Rendering tiles from scratch (planet imports, tilemaker/planetiler pipelines, custom tile servers). We cut regions from prebuilt sources and filter OSM data with existing tools.
- MapLibre offline packs and ambient caching as the offline mechanism (PMTiles sources do not support them). Offline means our own downloaded PMTiles.
- The GitHub REST API from clients (60 req/h unauthenticated). Clients use the `releases/latest/download/…` redirect only.
- Map-matching, routing, turn-by-turn. `MaqsData` exposes simple query APIs; matching a position to a segment is the app's job.
- App-specific map styles. The package ships one plain default style; apps bring their own look.
- Third-party Swift dependencies other than MapLibre Native, in any module, including tests.
- Map rendering on macOS. MapLibre's SwiftPM binary is iOS-only; `MaqsUI` is declared for iOS, the other three products also build for macOS (ADR 0003).
- A second map provider, a second terrain source, or any dormant tool. VersaTiles is the one map provider (ADR 0004); `curvature` and `cai_scripts` were evaluated and not adopted (ADRs 0005, 0006).
- Regions outside what `config/regions.yaml` lists. Adding a region is one entry there, nothing else.

Do not build toward these, and do not add abstractions that only make sense if they existed.

### Domain vocabulary
| Term | Meaning |
|---|---|
| Region | A named bbox with an id (`veneto`, `friuli-venezia-giulia`, `trentino-alto-adige`, `test`) and display names in `it` and `en`, declared in `config/regions.yaml`. The unit of download, build, and release. |
| `test` region | A few km² around Nevegal. Builds end to end in under 5 minutes; CI and the Swift tests use its outputs as fixtures. Not a toy: it exercises every layer. |
| Layer | One of `basemap`, `terrain`, `trails`, `places`, `curvature`. Apps declare which layers they need and only those are downloaded. Each layer has its own `layer_schema_version`. |
| Region pack | The set of per-layer files for one region, listed in the manifest. Not a single archive. |
| Basemap | Shortbread 1.0 vector tiles from VersaTiles, online from `tiles.versatiles.org/tiles/osm` and offline as `<region>-basemap.pmtiles` cut from `osm-landcover.versatiles` with `versatiles convert --bbox --compress gzip`. Same tiles both ways. |
| Shortbread | The vector tile schema (shortbread-tiles.org). Pinned to **1.0**, what VersaTiles serves, and recorded in the manifest. |
| Terrain | Terrarium-encoded DEM raster tiles (Mapterhorn's build, repackaged by VersaTiles): 512 px WebP, zoom 0–12, online from `tiles.versatiles.org/tiles/elevation`, offline cut from `elevation.versatiles`. **Same tiles online and offline** so the Swift sampler has one code path: elevation = (R × 256 + G + B / 256) − 32768. |
| Trails | Normalised trail records produced by **source adapters** (OSM is the first; Alpenverein Südtirol and regional networks are planned) and merged per region by priority, with provenance columns and both the normalised difficulty and the original value. A trail whose geometry cannot be ordered is *flagged*, never dropped silently and never a build failure. |
| Places | Peaks, volcanoes, saddles, passes, huts, shelters, and named villages/hamlets/isolated dwellings, with multilingual names, `ele`, `wikidata`, and a `rank_score` for label priority. |
| `rank_score` | Label-priority number per place: a `wikidata` tag is a strong notability signal, combined with elevation. The formula is simple and written down in `docs/data-format.md`; do not add inputs without updating both. |
| Curvature segment | A road way (or run of ways) with a curvature score computed by our own pipeline step (three-point-circle radius per segment, summed per way with the same bands the `curvature` project uses, ADR 0005), plus name, ref, highway class, surface, length, geometry. |
| Corner | A discrete curve on a segment: apex position, minimum radius (three-point circle over the way geometry), direction (left/right), entry/exit distance along the segment. |
| Manifest | `manifest.json` in the latest data release: `manifest_version`, `created_at`, `shortbread_version`, attribution list, and per region → per layer `file`, `url`, `bytes`, `sha256`, `layer_schema_version`. Fetched by clients from `releases/latest/download/manifest.json`. |
| `sources.json` | `config/sources.json`: the online providers per layer (basemap, terrain), today exactly one each (VersaTiles), with tile URL template or TileJSON URL, schema, attribution, max zoom. Fetched from `main`, cached, with a bundled copy as fallback. **No provider URL lives in Swift logic.** |
| Data release | A GitHub Release tagged `data-YYYY-MM`, marked latest, holding every region's files plus `manifest.json`. Re-running the same month replaces assets. Distinct from package version tags. |
| PMTiles | Single-file tile archive (v3). `MaqsTerrain` ships a minimal reader (header, directories, varints, gzip via Compression); MapLibre reads them via `pmtiles://file://…`. |
| Installed region | A region whose pack is downloaded, SHA-256 verified, and atomically installed in Application Support (excluded from iCloud backup). Inside an installed region's bbox the map must work with no network. |
| Metadata table | The `metadata` table every SQLite output carries: `schema_version`, `layer`, `region`, `data_date`, `osm_timestamp`, `attribution`. |

### Stack summary
Swift 6 language mode, strict concurrency, iOS 18+ / macOS 15+; SwiftPM package `Maqs` with four products — `MaqsCore` (manifest, sources, catalog, downloads, storage), `MaqsData` (SQLite readers: FTS5 + R*Tree), `MaqsTerrain` (PMTiles v3 reader, terrarium decoding, DEM sampling, profiles), `MaqsUI` (SwiftUI map view over MapLibre Native — the **only** module importing MapLibre). System frameworks only otherwise: SQLite3, Compression, CryptoKit, Network, URLSession. Swift Testing. DocC comments on the public API. `Examples/MaqsDemo` is a minimal SwiftUI app.

Pipeline: Python managed with `uv` in `pipeline/`, entry point `uv run maqs build --region <id> [--layers …]`, orchestrating three pinned external CLIs (`versatiles`, `osmium`, `tippecanoe`; `pmtiles` only to inspect archives) installed by `pipeline/bootstrap.sh` on macOS and Ubuntu, plus our own Python for trail assembly, places ranking, and curvature. GitHub Actions: `build-maps.yml` (monthly cron + dispatch, matrix per region, release job) and `swift.yml` (package build + tests on macOS runners for iOS Simulator and macOS).

**Vendors (data providers, all free, all credited):** **VersaTiles** for every map tile, online and offline (`tiles.versatiles.org` tilesets `osm` and `elevation`; `download.versatiles.org` files `osm-landcover.versatiles` and `elevation.versatiles`), and **Geofabrik** for OSM data (`europe/italy/nord-est` PBF). Upstream credits: OpenStreetMap contributors (ODbL), ESA WorldCover 2021 (CC BY 4.0), Mapterhorn and its DEM sources. Terms and attribution strings are recorded in `DATA_LICENSE.md` and `docs/decisions.md`. Adding a provider or a trail source is an ADR plus a config change — never a Swift change. **Only code dependency:** MapLibre Native iOS via SPM, pinned. Adding any other package requires an ADR and explicit approval.

**Infrastructure as code:** the GitHub Actions workflows *are* the infrastructure. There is nothing else: no cloud account, no state backend. The few repository settings that cannot be code (release "latest" marking is done by `gh` in the workflow; branch protection, topics, description) are recorded in `docs/decisions.md` when they matter. CI uses only the default `GITHUB_TOKEN`.

### Environments
| Environment | Purpose | Shared? | Reach it via |
|---|---|---|---|
| local (macOS) | package build/tests, `test`-region pipeline runs, the demo app | no | `swift build` / `swift test`, `uv run maqs build --region test`, Xcode for the demo |
| CI `ubuntu-latest` | the data pipeline per region | no (ephemeral) | `build-maps.yml` |
| CI `macos-latest` | package build + tests, iOS Simulator and macOS | no (ephemeral) | `swift.yml` |
| GitHub Releases `data-YYYY-MM` | **the production data endpoint**: every installed app fetches `releases/latest/download/manifest.json` from here | **yes — public, consumed by shipped apps** | `gh release` from the workflow only; never hand-upload |
| `main` | **also production**: clients fetch `config/sources.json` from `main` at runtime | **yes** | push |

### Repository map
```
docs/BRIEF.md              # the brief: goals, locked decisions, phases — what to build
docs/decisions.md          # ADR log, one short ADR per non-obvious choice; Phase 0 findings open it
docs/architecture.md       # modules, data flow, online/offline switching
docs/data-format.md        # every file format and SQLite schema, versioned — the contract apps read against
DATA_LICENSE.md            # ODbL notice + every attribution string the data requires
Package.swift              # package "Maqs", four products, MapLibre is the only dependency
Sources/MaqsCore/          # manifest, sources.json, region catalog, downloads, storage — no MapLibre, no SQLite
Sources/MaqsData/          # SQLite3 readers: trails, places, curvature — read-only, async
Sources/MaqsTerrain/       # PMTiles v3 reader, terrarium decoding, DEM sampling — no MapLibre
Sources/MaqsUI/            # MapLibre integration, style assembly, overlays, attribution view — the ONLY `import MapLibre`
Tests/<Module>Tests/       # one Swift Testing target per module; fixtures = test-region outputs, small
Examples/MaqsDemo/         # minimal SwiftUI app to eyeball everything; not a product
config/sources.json        # online providers, priority order — fetched by clients from main
config/regions.yaml        # region id, names (it/en), bbox — adding a region is one entry here
config/schemas/            # JSON Schemas for manifest.json and sources.json; CI validates against them
pipeline/                  # Python (uv) orchestrator + per-layer steps; bootstrap.sh installs pinned CLIs
.github/workflows/         # build-maps.yml (data) and swift.yml (package)
.cache/                    # downloaded inputs (gitignored, idempotent reuse)
dist/<region>/             # build outputs (gitignored; Releases only, never git)
```

### Commands
Everything below is the contract from the brief. Until the matching phase lands, the command does not exist; do not fake it.
```
# Swift package — the "done" bar for Swift changes (build + all module tests)
swift build
swift test
swift test --filter MaqsTerrainTests                      # one target
swift test --filter MaqsTerrainTests/TerrariumTests        # one suite; append /testName for one case

# iOS Simulator leg (what swift.yml runs; adjust the destination to an installed simulator)
xcodebuild -scheme Maqs -destination 'platform=iOS Simulator,name=iPhone 17' build test

# Pipeline
pipeline/bootstrap.sh                                      # install pinned CLIs (macOS / Ubuntu)
uv run maqs build --region test                            # end-to-end in < 5 min; the pipeline's "done" bar
uv run maqs build --region veneto --layers basemap,terrain # one real region, a subset of layers
uv run pytest                                              # pipeline unit tests (from pipeline/)
uv run ruff check . && uv run ruff format --check .        # pipeline lint/format

# Data release (the workflow does this; run by hand only to debug)
gh release view --json tagName,assets                      # inspect the latest data release
```
Grep xcodebuild output for `": error:"`; a bare `error` matches unrelated tool paths. Swift Testing prints a fake XCTest summary ("Executed 0 tests") — read the `Test run with N tests` line.

**Scratch directory:** the harness-provided session scratchpad for temporary files. Nothing under the repository root is scratch; `.cache/` and `dist/` are build state, not scratch.

### Tool map
| Topic | Consult |
|---|---|
| Code search in this repo | Serena MCP (`find_symbol`, `find_referencing_symbols`, `search_for_pattern`, `find_file`) once there is code; `grep`/`rg` for non-code text (YAML, JSON, docs, build logs) |
| MapLibre Native iOS (SPM, `pmtiles://`, style spec, network configuration, User-Agent) | Context7 MCP first; the MapLibre docs and release notes for the pinned version (6.31.0). The verified facts are in ADR 0001 |
| PMTiles spec, `versatiles`, `osmium`, `tippecanoe`, pyosmium | Context7 where indexed, otherwise the project's own README/docs via web fetch; pin the version you read against in `pipeline/bootstrap.sh` |
| Provider terms, usage policies, attribution, URLs, sizes | **The live page, every time** (docs.versatiles.org, download.versatiles.org, mapterhorn.com, Geofabrik). Record what you verified and the date in `docs/decisions.md`. Never a remembered URL or limit. |
| Apple frameworks (URLSession background sessions, Compression, CryptoKit, SQLite3 on Apple platforms, NWPathMonitor, SwiftUI) | Context7 MCP, then the matching repository skills (`swift-concurrency`, `swift-testing`, `ios-networking`, `background-processing`, `swiftui-*`, `swift-security`). Check availability per platform |
| Swift package layout, test targets, DocC | `swift-architecture`, `swift-api-design-guidelines`, `swift-testing` skills |
| Building the demo app on a simulator | XcodeBuildMCP (call `session_show_defaults` first); the package itself builds with `swift build` |
| GitHub Releases, Actions, `gh` | `gh` CLI (the GitHub MCP plugin is disabled for this repo); `cicd-automation:github-actions-templates` skill for workflow patterns, then verify against current Actions docs |
| Brainstorming / planning / TDD / debugging / review | the superpowers skills — invoke rather than approximate; `code-review` for the fresh-context review |
| Prose the user will post (PRs, commits, ADRs, release notes, README) | the `humanizer` skill, then §13 *Writing for people* |

### Never hand-edit — regenerate or migrate instead
- `Package.resolved` — change `Package.swift` and `swift package resolve`
- `uv.lock` — change `pipeline/pyproject.toml` and `uv lock`
- Anything under `dist/` or `.cache/` — rerun the pipeline step
- `manifest.json`, `build-report.json`, checksums — generated by the pipeline's release step; a hand-edited manifest is a corrupted release
- Release assets — re-run the workflow for the month; never upload a file by hand
- The bundled fallback copy of `sources.json` inside the package — it is a copy of `config/sources.json`, synced by the build; edit the source
- Bundled glyphs and sprite — generated from the chosen open font; regenerate with the documented command, never patch PBF glyph files
- `docs/data-format.md` schema versions — a schema change bumps `layer_schema_version` and documents the compatibility rule in the same change; never edit a published version's description in place

### Conventions
- Swift: Swift API Design Guidelines; one primary type per file, filename = type name; `public` surface explicit and DocC-documented; everything else `internal`. Swift 6 strict concurrency: value types `Sendable`, readers are actors or `Sendable` structs over a connection, `@MainActor` only on SwiftUI-facing observable state. No `try!`, no force unwrap outside tests, no `fatalError` on a recoverable path, no `@unchecked Sendable` without a written justification.
- Python: `ruff` (lint + format) at strict settings; type hints everywhere; `pathlib` not string paths; subprocess calls go through one helper that logs the command, pins the binary, and raises on non-zero exit. No shelling out via `shell=True` with interpolated strings.
- Errors (Swift): typed `Error` enums per module (`ManifestError`, `DownloadError`, `PMTilesError`, `QueryError`) with `LocalizedError` descriptions that say what to do; `throws`, never `nil` for a failure. A reader with no installed region returns an empty result or a typed "not installed" error as the API documents — never crashes, never pretends.
- Errors (pipeline): a step fails loudly with the failing command and its output; a *data* anomaly (broken relation, missing tag) is recorded in `build-report.json` and the build continues. The 1.9 GiB asset limit is a hard failure. `[ENFORCED: CI]`
- Logging (Swift): `os.Logger`, subsystem `com.lucavallin.maqs`, one category per module (`core`, `data`, `terrain`, `ui`). Never log full URLs with query strings, file contents, or a user's coordinates (`privacy: .private` for anything position-derived).
- Logging (pipeline): the standard `logging` module, one logger per step, machine-readable `build-report.json` as the durable record.
- Validation at trust boundaries: `manifest.json` and `sources.json` are validated against `config/schemas/` on the pipeline side and parsed with strict `Codable` on the Swift side (unknown `manifest_version` → typed error, not a crash). Downloaded files are verified by SHA-256 before install. PMTiles headers and directories are bounds-checked before any read — the file may be truncated, corrupt, or hostile.
- Vendor boundary: `import MapLibre` only inside `Sources/MaqsUI/`. `[ENFORCED: CI import check once Phase 4 lands]`
- Geometry storage: one encoding (encoded polyline or float32 blob — chosen by ADR in Phase 1) used by every layer. Do not add a second.
- Identifiers: OSM ids are stored as-is with their type (`relation`/`way`/`node`) — never collapsed into one integer space. Region ids are lowercase kebab-case and are stable forever once released.
- Accessibility target: the attribution view and anything else `MaqsUI` renders is VoiceOver-labelled and respects Dynamic Type; the map view itself is MapLibre's. Smallest supported viewport: whatever the app chooses — the package makes no layout assumptions.
- Timestamps in files and manifests are ISO 8601 UTC. Sizes are bytes. Coordinates are WGS 84 lon/lat in that order in data files, `CLLocationCoordinate2D` in Swift.

### Data classification
| Class | Examples | Handling |
|---|---|---|
| Public | everything in the repo, every release asset, every manifest field, OSM-derived data (ODbL), terrain (see attribution), provider URLs | free to log, fixture, document — subject to attribution in `DATA_LICENSE.md` |
| Internal | nothing. This is a public repo with no internal tier; anything that would be internal belongs to the consuming apps' repo, not here | — |
| Personal | the device's position, which the apps pass into `MaqsData`/`MaqsTerrain` queries | never logged unredacted, never sent anywhere by this package (tile requests carry tile coordinates, not the user's exact position — note the zoom-level implication in docs), never in fixtures |
| Secret | none. CI uses the default `GITHUB_TOKEN`; no provider requires a key | a provider that starts requiring a key is a vendor change (ADR), not a secret to add |

### Security-critical paths
- **Download and install (`MaqsCore`)** — bytes from the network land on the user's disk. SHA-256 verified against the manifest before atomic install; partial files never visible to readers; resumable without trusting the partial content; excluded from iCloud backup. A bad checksum is rejected and reported, never "installed anyway".
- **Manifest and `sources.json` parsing** — the manifest decides what gets downloaded and from where; `sources.json` decides which hosts the app talks to. Strict schema, HTTPS only, hosts limited to what the file declares, no URL assembled from user input. An old client must find data it understands (the compatibility rule in `docs/data-format.md`); an unknown version is a typed error.
- **PMTiles reader (`MaqsTerrain`)** — parses untrusted bytes from local files and online responses. Every offset, length, and varint is bounds-checked; a corrupt file is a typed error, not a crash or an unbounded allocation.
- **Provider usage compliance (`MaqsUI`, `MaqsTerrain` online path)** — VersaTiles is a free demo server with a per-IP rate limit. An identifying User-Agent is set on MapLibre's network configuration and on URLSession; cache headers are never overridden to no-cache; 429 is backed off, never retried in a tight loop. Getting the apps blocked is the failure mode.
- **The release workflow** — publishes to the endpoint every installed app reads. Asset size limit, schema validation, checksums, and the manifest's compatibility rule all run before `gh release` is called. A failed region must not produce a partial "latest".
- **`config/sources.json` on `main`** — a push changes what shipped apps do at runtime. Validate against the schema in CI; treat edits as a production change (plan tier, never direct).

### Budgets
| Metric | Budget |
|---|---|
| Release asset size | **< 1.9 GiB each**, hard CI failure above (GitHub's limit is 2 GiB) `[ENFORCED: CI]` |
| `test` region, full pipeline | **< 5 minutes** end to end, locally and in CI |
| GitHub API calls from clients | **0**. Only `releases/latest/download/…` and raw `main` fetches |
| Third-party Swift dependencies | **1** (MapLibre Native), linked by `MaqsUI` only; `MaqsCore`/`MaqsData`/`MaqsTerrain` link none |
| Network calls inside an installed region | **0** for basemap, terrain, glyphs, sprites, overlays — the no-network map is a requirement, not a nice-to-have |
| Offline terrain tile cache / online LRU | bounded, stated in the ADR for the terrain path; no unbounded in-memory tile caches |
| Planet downloads | **0**. VersaTiles and Protomaps extracts are remote range requests; Geofabrik nord-est is the only full download, once per run, cached |
| Build warnings (Swift, `-warnings-as-errors`) | 0 |

**Metered resources:** GitHub Actions minutes (unlimited on public repos, but macOS runners are slow and queue — keep `swift.yml` under control and skip it on data-only changes); GitHub Release bandwidth and storage; the goodwill of free providers (VersaTiles, OSMF, Protomaps, AWS Open Data, Geofabrik) — one Geofabrik download per run, extracts by range request, no re-runs for fun. A change that adds requests per app launch, per tile, or per pipeline run says so with a rough number.

### Test layers and placement
| Layer | Tool | Scope | Location / naming |
|---|---|---|---|
| Swift unit | Swift Testing (`@Suite`/`@Test`) | manifest/schema parsing (valid, each invalid case, unknown versions), compatibility rule, PMTiles reader against fixtures (valid, truncated, corrupt), terrarium decoding with known values, bilinear sampling, profile corrections, SQLite queries against `test`-region fixtures, download verification (bad checksum rejected, atomic install), style assembly online/offline, attribution correctness | `Tests/<Module>Tests/<Type>Tests.swift`, one target per product |
| Pipeline unit | pytest | corner detection geometry (three-point radius, direction), `rank_score`, relation ordering and flagging, size limit, checksum/report generation, schema validation | `pipeline/tests/test_<step>.py` |
| Pipeline end-to-end | `uv run maqs build --region test` | every layer, every output, validated and under budget; produces the Swift fixtures | CI `build-maps.yml` on PRs (test region only) |
| Demo / manual | `Examples/MaqsDemo` | online map, download test region, airplane-mode map, trail search, places along a bearing, elevation profile | run by hand before a package release; steps in the README |

Fixtures are the `test` region's outputs plus tiny hand-built PMTiles/SQLite files for corruption cases. Never a real region's files, never anything over a few MB, never a user's position.

**Test exemption policy:** `default` — docs, formatting, and config-only changes ship without tests. A change to `config/sources.json`, `config/regions.yaml`, or the schemas is *not* config-only: it is validated by CI and, for the schema, covered by parsing tests.

### Documentation suite
| Document | Job | Location |
|---|---|---|
| README | what this is, how to use the data and the package, how to add a region, licenses, links to everything else | `README.md` |
| Brief | goals, locked decisions, phases — what to build | `docs/BRIEF.md` |
| Decisions | ADR log: one short ADR per non-obvious choice, Phase 0 verification findings first, each dated, each flagging any contradiction with the brief | `docs/decisions.md` |
| Architecture | modules and their dependency direction, data flow, the online/offline switching strategy, the download/install state machine | `docs/architecture.md` |
| Data format | every file format and SQLite schema, versioned; the manifest and `sources.json` formats; the client compatibility rule; the geometry encoding; the `rank_score` formula | `docs/data-format.md` |
| Data license | ODbL notice plus every attribution string every provider requires, verbatim | `DATA_LICENSE.md` |
| Security | disclosure contact; threat notes for downloads, parsing, provider compliance | `SECURITY.md` |
| Contributing / conduct | how to add a region or a provider, how to run the test region, PR expectations | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` |
| This file | engineering contract: how to work here | `CLAUDE.md` |

`docs/decisions.md` is a single file with short ADRs (the brief chose this over one-file-per-ADR); keep the format consistent: date, title, context, decision, consequences, status. Public Swift API is documented with DocC comments; the README links the package products and what each is for.

### Things that will bite you
- **Phase 0 is a stop.** The brief says verify, record, summarise, wait. Do not start Phase 1 because Phase 0 went well.
- **"Decisions already made" are fixed, but their facts are not.** Every URL, license, version, size, and capability in the brief must be re-verified against the live source in Phase 0. If one is wrong, stop and report before building on it — do not quietly substitute.
- **tiles.versatiles.org is a demo server.** No SLA, per-IP rate limit answered with 429 and no Retry-After, six-hour `Cache-Control`, no ETag (every revalidation is a full download), data refreshed roughly quarterly. Send an identifying User-Agent, never no-cache, back off on 429. The provider swap lives in `sources.json`, so an outage is a config change, not an app update.
- **MapLibre reads PMTiles with gzip or no compression only.** VersaTiles writes brotli by default; every basemap extract passes `--compress gzip` or MapLibre throws "Compression method not supported".
- **`osmium export` does not assemble route relations**, only multipolygons and boundaries; member ways come out with their own tags. Trail geometry is our pyosmium step. And 5–10 % of hiking relations cross region borders: read relations from the uncut nord-est file, not the clipped region PBF.
- **PMTiles sources cannot use MapLibre offline packs** (an ambient cache for remote PMTiles exists since 6.27, irrelevant to us). Offline is our PMTiles files plus bundled glyphs and sprite; a style that references remote glyphs or sprites breaks offline silently (labels disappear).
- **`releases/latest/download/<asset>` resolves "latest" by GitHub's rules** (most recent non-draft, non-prerelease by creation date). Re-running a month must update the existing release's assets, not create a second release with the same tag or a prerelease; verify the behaviour and record it in Phase 3's ADR.
- **GitHub Release assets are capped at 2 GiB**; we enforce 1.9 GiB. A region that exceeds it needs a split or a lower max zoom — decided by ADR, never by raising the limit.
- **No Git LFS, no generated data in git.** `dist/` and `.cache/` are gitignored; a `.pmtiles` or `.sqlite` in a commit is a mistake to revert, not to keep.
- **The GitHub REST API is 60 requests/hour unauthenticated.** One app checking for updates via the API would exhaust it across a few users. Clients never call `api.github.com`.
- **Online and offline terrain are the same VersaTiles tiles** (terrarium, WebP, z0–12). A provider that serves Mapbox Terrain-RGB or PNG at other zooms is not a drop-in; the sampler has one decode path by design. z12 is ~27 m per pixel at our latitude; higher zooms exist only in Mapterhorn's regional archives and would exceed the asset limit for a whole region.
- **FTS5 and R*Tree on Apple's system SQLite** were verified by a compiled probe on macOS and the iOS simulator (ADR 0001); `SQLITE_OMIT_LOAD_EXTENSION` is set, so no loadable extensions, ever.
- **Hiking relations are often broken** (gaps, reversed ways, roles). The build flags them in `build-report.json` and keeps going; a pipeline that fails on bad OSM data never ships a month.
- **`versatiles convert --bbox` on a remote `.versatiles` file is a range-request extract.** If a step is downloading the whole planet file, something is wrong — stop it.
- **macOS CI runners are slow and scarce.** `swift.yml` must not run on data-only or docs-only changes; use `paths` filters. Diagnose locally, batch fixes, never re-run CI casually.
- **Free disk space on `ubuntu-latest` is small** relative to a Geofabrik PBF plus extracts plus tiles. The workflow frees space up front and the matrix job must not download the PBF per region (shared artifact or cache).
- **`swift test` on macOS does not exercise the iOS Simulator leg**; availability differences (`Network.framework`, background `URLSession` behaviour) only show there. Run the simulator leg before declaring Phase 4 work done.
- **Swift Testing prints a fake XCTest summary** ("Executed 0 tests"); read `Test run with N tests`. Grep xcodebuild output for `": error:"`, not `error`.
- **Ubuntu's apt ships old osmium-tool (1.16) and tippecanoe (2.49).** `bootstrap.sh` fetches or builds current versions on Linux; Homebrew is current on macOS.
- **GitHub picks "latest" by the tagged commit's date**, not the publish date. After re-uploading a month's assets, call `gh release edit <tag> --latest` explicitly.
- **The package must never know the apps.** A "small convenience for the app" that leaks an app's name, style, or assumptions into `Sources/` is scope creep into a different repo.

### Git and CI
- Solo-maintainer repo: commit and push **directly to `main` when asked** — this deliberately overrides §13's open-a-PR rule until branch protection is enabled. Never force-push. The brief asks for one commit per phase (or per meaningful chunk within one).
- Commit style: `type(scope): summary` conventional-ish messages with a body that records diagnoses and decisions.
- Merge bar (CI gates): `swift.yml` — build + tests on iOS Simulator and macOS, warnings as errors; `build-maps.yml` on PRs — `test` region end to end, schema validation, size limit, checksums. Both from a clean checkout.
- Versioning: the **package** follows SemVer tags `vX.Y.Z` (consumers pin a version); **data** releases are `data-YYYY-MM`, monthly, latest-marked. A breaking change to a file format bumps that layer's `layer_schema_version`; a breaking change to the manifest bumps `manifest_version`; both are documented with the compatibility rule in `docs/data-format.md`.
- Public API stability: the Swift public API follows SemVer (additive in minor, removals only in major after a deprecation window with `@available(*, deprecated)`). The data formats are the other public API: an old client must find data it understands in a new manifest — that rule is in `docs/data-format.md` and is tested.

---

## 2. Tools, skills, plugins, and MCP servers

Training data goes stale; the tools available in the session do not. Use them.

- **Inventory at session start.** Note which skills, plugins, subagents, and MCP servers are available. Before writing code that touches a library, platform, service, or UI component, consult the matching source from the §1 tool map — or, if none is mapped, the closest available documentation tool.
- **Skills over improvisation.** Where a skill or plugin exists for a procedure — brainstorming, planning, test-driven development, systematic debugging, code review, verification before completion, git workflow — invoke it rather than approximating it from memory. Read any repository skill in `.claude/skills/` before working in its area.
- **Fetch, do not transcribe.** If a tool can produce an artefact verbatim (a component, a schema, generated types, a provider resource definition), use it; do not hand-write what a tool can generate.
- **Never invent API surface.** If you cannot confirm a signature, a config key, a limit, or a price from a live source, look it up. If you still cannot confirm it, say so; never present a guess as fact.
- **Isolated contexts for review and side tasks.** Use a subagent or review tool for the self-review in §3 and for any investigation that would flood the main context.
- **Propose the harness feature, not just the code.** When a request, a repeated correction, or a mistake you just made would have been prevented or made cheaper by a Claude Code capability this repo does not use yet — a hook for "every time X", a `.claude/rules/` file for a path-scoped constraint, an isolated worktree or subagent for parallel or risky work, a scheduled or looped run for a recurring check — say so in one line with the concrete config, and let the user decide. Check the current Claude Code documentation before proposing; do not describe a feature from memory.

### Procedure → tool
The specific skill or plugin names for this repo are in the §1 tool map. If no skill is installed for a procedure, perform it inline following the same steps; the procedure is mandatory, the tool is a convenience.

| When | Use |
|---|---|
| Before proposing an approach | brainstorming skill (§3 Phase 1) |
| Before writing code for a non-trivial change | planning skill (§3 Phase 2) |
| Implementing behaviour | test-driven-development skill: failing test, minimal code, refactor |
| Something is broken and the cause is not obvious | systematic-debugging skill: reproduce, hypothesise, bisect, fix, regression test |
| Change implemented | code-review skill or review subagent in a fresh context (§12) |
| Before declaring done | verification skill or the §3 done list, once |
| Touching a library, platform, or component | the §1 tool map source for that topic |
| Writing anything a person will read or post — PR description, PR comment, ticket, team message, changelog entry | the prose skill named in §1, then the §13 *Writing for people* rules |
| Any repeated multi-step procedure specific to this repo | the matching skill in `.claude/skills/`; propose one if it is missing |

## 3. Workflow

### Tier the work
- **Direct:** the diff can be described in one sentence and has no behavioural effect a user or caller would notice (a typo, a rename, a comment, a config value). Do it.
- **Plan only:** a behavioural change whose approach is obvious and whose blast radius is one module — a well-understood bug fix, a small addition matching an existing pattern. Skip Phase 1; write the Phase 2 plan, get approval, implement.
- **Full:** anything multi-file, unfamiliar, ambiguous, architectural, or touching a §1 security-critical path. All three phases.

When in doubt, take the heavier tier. If hidden complexity appears mid-change, stop, say so, and step up a tier. **When running unattended** — a scheduled job, a loop, a CI task, no one to approve — say so at the start, restrict yourself to the direct tier or the scope the task explicitly pre-approved, and leave anything larger as a written plan for a human.

### Always, at every tier
- **Before editing a file**, read its exports, its immediate callers, and the shared utilities it uses. Find the closest existing pattern and match it; do not introduce a parallel one.
- **Work in small, verifiable steps:** each step has a check that proves it worked before the next begins.
- **After implementing** (plan-only and full tiers), review the diff once in a fresh context (§1 review tool) against §12, scoped to correctness and the stated requirements. Report gaps; do not report style preferences. Direct-tier changes skip this; the check command is their review.
- **Done** means all of the following are true — stated once here, checked once at the end, not repeated as a ritual:
  - the §1 check command and the relevant tests are green, with the exact commands and results in the report; `[ENFORCED: CI]`
  - tests exist at every applicable layer for the behaviour changed;
  - §13 documentation obligations met in the same diff;
  - the §9 observability obligations are met: the change's failure is visible somewhere a human will look, and the metric or alert that covers it is named in the report;
  - the repository would still be publishable today;
  - and, for plan-only and full tiers: the plan was followed or its deviations re-approved; §12 review done in a fresh context with findings reported; the rollback path is stated.
  If any item is outstanding, say which, rather than presenting the work as finished.
- **Three failed attempts** at the same problem means stop, summarise what you tried, and ask. Do not thrash.
- **Scratch files** go in the scratch directory named in §1 and are deleted before you finish.

### Phase 1 — Understand and brainstorm
Use the brainstorming skill named in §1. Before proposing anything, state explicitly:
- The problem, restated in your own words. Half of bad changes are answers to a misread question.
- At least two viable approaches with real trade-offs, including "do nothing" and "does this belong in this codebase at all".
- What could break, and the blast radius: which callers, which data, which environments.
- Which §1 tools and sources you will consult, and any assumption you are making that the request did not state.

### Phase 2 — Plan
Use the planning skill named in §1. The written plan covers:
- Files to create, modify, or delete, and the smallest approach that fully solves the request.
- Anything you are tempted to add that was not asked for — named, so it can be declined.
- Migrations or infrastructure changes required, and their expand/contract sequencing.
- Tests to write, and what each one proves.
- Documentation to add or update, including an ADR if the decision is expensive to reverse.
- Rollback story: how is this undone if it goes wrong in production?
- Observability story (§9): how you will know this is working in production, what signal shows it failing, and which alert or dashboard carries that signal.
- Cost and performance impact against §1 budgets, if plausible.

Present the plan and wait for approval. Do not implement and then ask. If the plan changes materially during implementation, stop and re-present it.

### Phase 3 — Implement
Follow the approved plan. If you discover it was wrong, say so and revise it; do not silently improvise a different design. Then apply the *Always* list above.

## 4. Scope

- Every changed line traces to the request. No unsolicited refactors, no touching unrelated files, no drive-by improvements to adjacent code.
- Clean up only orphans your own change created. Found unrelated dead code or an unrelated bug? Mention it; do not fix it in this change.
- **Ask before** any of these, or anything else that is hard to reverse: adding a dependency (per the policy below); changing a public API; changing a schema; changing the architecture or adding a layer; touching a §1 security-critical path.
- One logical change per pull request. If the diff touches several concerns, split it. Small changes get reviewed properly, fail in isolated ways, and revert cleanly.

### Dependency policy
- The standard library and existing dependencies are the default. A new dependency earns its place by doing something substantial that would otherwise be a meaningful amount of code to write and maintain.
- For each proposed dependency state: what it does, why the standard library or an existing dependency cannot, its licence and compatibility with the project's licence, maintenance status, transitive footprint, and impact on §1 budgets.
- Prefer one well-maintained dependency over several small ones; prefer libraries that expose a narrow interface that can sit behind the §1 boundary layer.
- Remove a dependency when the last use goes; a manifest is not an archive.

## 5. Simplicity and code quality

- Prefer the smallest change that fully solves the request. No features, abstractions, configuration, or flexibility beyond what was asked; no speculative interfaces for a second case that does not exist yet. The third occurrence justifies extraction, not the second.
- Minimise scope, never correctness. Input validation and safety checks are always kept. In §1 security-critical paths, handle the "impossible" states too.
- Write code that reads like the surrounding code: match its idiom, naming, structure, and comment density. Follow the language's canonical style guide, error-handling conventions, and standard tooling; do not import patterns from another language or framework.
- The repository's formatter and linter configuration is the authority on style, at the strictest reasonable settings. No suppression without a comment stating why. `[ENFORCED: CI lint]`
- Names say what a thing is; no abbreviations that need a glossary. Comments explain *why* and record trade-offs; they do not restate *what*. No dead code, no commented-out blocks, no `TODO` without a linked issue.
- Boring, obvious code over clever code. If a competent developer who has never seen this codebase could not understand a change in one pass, simplify it or comment the reason it cannot be simpler.
- Configuration comes from the environment; nothing deployment-specific (a region, an account, a domain) is hardcoded; `.env.example` lists every variable with a description and a safe placeholder. `[ENFORCED: CI]`

## 6. Architecture and design

Apply these as judgment, not as a checklist to satisfy. The goal is code that a contributor can change safely without reading everything.

- **Layering and dependency direction.** The change fits the layering described in the §1 architecture document; if it does not, that document changes first, deliberately. Dependencies point inward — domain logic does not import delivery, storage, or vendor code. No circular dependencies.
- **Boundaries are explicit.** Vendor and SDK code stays behind the internal boundary layer named in §1; application code never imports a vendor directly. Process, network, and trust boundaries (server/client, service/service, user/system) are visible in the code, not implied. `[ENFORCED: CI import rules, where configured]`
- **Single responsibility.** A module, type, or function has one reason to change. If describing what it does needs "and", split it.
- **Open for extension by composition,** not by modifying stable code — but only once the second real case exists (see §5).
- **Substitutability.** Anything that implements an interface honours its full contract, including error behaviour; no implementation that callers must special-case.
- **Small, client-shaped interfaces.** Callers depend on the narrow interface they use, not on a wide one they mostly ignore.
- **Depend on abstractions at boundaries only.** Inject dependencies where testability or swapping matters (vendors, clocks, randomness, I/O); do not abstract pure domain code that has one implementation.
- **Data flow.** State has one owner; data is validated once at the boundary and trusted inside; derived data is computed, not duplicated. Schemas or types for inputs are the single source of truth — infer, do not redeclare.
- **APIs and contracts.** Consistent naming, shape, and error format across endpoints or public functions. Public surface is versioned and follows the §1 deprecation policy: additive changes first, removals only after a deprecation window.
- **Failure design.** Every external call can fail, time out, or return garbage; decide per call whether to retry, degrade, or surface, and make operations that can be retried idempotent.
- **Concurrency and idempotency.** Any operation that can run twice — retries, duplicate events, double submits, parallel workers — is idempotent or guarded by a unique constraint or lock. Shared mutable state has one owner and one synchronisation mechanism.
- **Configuration and feature flags** are read once at a boundary and passed in; code deep in the domain does not read the environment. Flags have an owner, a default, and a removal date.
- **Modules over frameworks.** Do not build a plugin system, registry, or generic engine where a function or a small module would do. Generality is a cost paid by every reader.
- **Expensive-to-reverse decisions** — a vendor, a schema shape, an auth model, a storage layout, a public API shape — get an ADR before implementation.

### Data modelling
- Every record has a stable identifier, creation and update timestamps, and follows the §1 conventions. Prefer constraints in the database over checks only in code; the database is the last line of defence.
- Model the domain vocabulary in §1 directly; a term that has a precise meaning gets its own type or table, not a flag on a neighbouring one.
- Deletion is a design decision: hard delete, soft delete, or anonymise, chosen per data class in §1 and applied consistently. Cascades are explicit and tested.
- Migrations are the only path to a schema change (§13). Schema and generated types stay in sync in the same change.

## 7. Testing

- Every behavioural change ships with tests at the applicable §1 layers, covering the failure paths, not just the happy one. Exemptions follow the §1 policy. "Hard to test" is a design smell: reconsider the design before skipping the test.
- A bug fix starts with a regression test that fails before the fix.
- Never edit, weaken, skip, or delete an existing test to make it pass. If a test is wrong, say so and change it deliberately, in its own commit, with the reason. `[ENFORCED: CI on clean checkout; test-file diffs reviewed]`

### What to test, by kind of code
- **Domain logic and pure functions:** near-total coverage; boundary values, invalid input, and the arithmetic that money, quotas, or permissions depend on.
- **Input validation:** every schema with valid input, each invalid case individually, and boundary values. A permissive schema is a security hole.
- **Handlers, endpoints, actions:** authorised success, unauthenticated rejection, wrong-principal rejection, invalid input rejection, limit-exceeded rejection. Test the authorisation branch explicitly; never assume it because the happy path works.
- **Inbound events and webhooks:** valid signature accepted; invalid and missing signature rejected; duplicate delivery handled idempotently; unknown event type ignored without error; out-of-order delivery resolved correctly.
- **Background jobs and workflows:** each step in isolation, plus failure and retry. A failure at step N must not redo steps 1..N-1, and a permanently failed job must leave a visible failed state with a reason, never a row stuck in progress.
- **User interface components:** every state the component can be in — loading, empty, error, populated, disabled, interactive. Assert on accessible roles and labels rather than styling or test IDs, so tests double as accessibility checks.
- **Data access policies and constraints:** owner can read and write; unrelated principal cannot; anonymous sees only what is public; cascades and triggers behave. Access-control bugs never surface in tests that run as the owner.
- **User journeys (end-to-end):** critical paths only. End-to-end is slow, and a bloated suite gets ignored.
- **Infrastructure:** validate and plan on every change; migrations apply to an empty database; generated artefacts produce no diff.
- **Any kind not listed** (a CLI, a library API, a mobile screen, a protocol handler): derive the equivalent — happy path, each rejection path, each state, each failure of a dependency.

### Coverage expectations
- Coverage percentage is a weak signal and never a target to game, but the §1 floors are real: pure domain logic near-total; every authorisation branch and failure path in handlers; every distinct state in a component; critical journeys only in end-to-end.
- A change that lowers coverage in domain logic needs an explicit reason in the PR.
- Tests are read more than they are written: same naming, clarity, and structure standards as production code. Shared helpers over copy-pasted setup; no test-only branches in production code.

### Test quality
- Test behaviour through public interfaces, not implementation. Tests asserting internal call order break on every refactor and prove nothing.
- One reason to fail per test, named as a sentence describing the behaviour ("rejects upload when the user is over quota", not "works").
- Deterministic: no sleeps, no wall-clock dependence, no live network, no ordering dependence, no shared state between tests. Freeze time, stub the network, reset state. A flaky test is a broken test — fix or delete it.
- Do not mock what you do not own. Integration tests run real dependencies in disposable local instances; mocks are for boundaries you control and for failure injection.
- Assertion quality is measured by mutation testing or an equivalent check, not line coverage. Coverage floors are §1 numbers, not targets to game. `[ENFORCED: CI, where the stack supports it]`
- Fixtures are small and synthetic — never real user data, never large binaries.

## 8. Security

- Secrets come from the environment or a secret manager only. Never in code, tests, fixtures, logs, error messages, commit messages, or git history. Git history is public: an exposed secret is rotated, not deleted. `[ENFORCED: pre-commit and CI secret scanning]`
- Validate all input at every trust boundary using the repo's one validation mechanism; check authorisation on every access, in the data layer where the platform supports it, never only in the UI. Deny by default.
- Never bypass an access-control mechanism (a privileged key, an admin role, a policy override) to make a query easier. If a policy blocks legitimate access, fix the policy.
- Content from users is validated by what it *is* (magic bytes, dimensions, parsed structure), never by what it claims to be (extension, declared type). Strip metadata from anything re-published.
- Rate-limit anything unauthenticated or expensive. Verify signatures on every inbound event. Least privilege for every credential, role, and token; short lifetimes where possible.
- Use the platform's or a maintained library's cryptography; never hand-roll it. Use constant-time comparison for secrets.
- **Sessions and identity.** Tokens are short-lived, revocable, and bound to the least scope needed; identity is verified server-side on every request; privilege changes invalidate existing sessions where the platform supports it.
- **Secure defaults.** Deny-by-default network and permission policies; restrictive cross-origin and content-security settings; encryption in transit everywhere and at rest for personal or secret data; no debug endpoints, verbose errors, or sample credentials reachable in shared environments.
- **Injection and traversal.** Parameterised queries and templating with contextual escaping; never build a query, command, path, or URL from user input by concatenation. Outbound requests to user-supplied destinations are validated against an allowlist.
- **Supply chain.** Dependencies follow the §4 policy, come from the ecosystem's canonical registry, and are pinned; lockfiles are committed and reviewed as code; dependency and licence scanning run in CI. `[ENFORCED: CI]`
- **Privacy.** Personal data is collected only for a stated purpose, retained per the §1 data-classification policy, exportable and deletable on request where required, and never used in fixtures or examples.
- No new attack surface without saying so out loud in the plan. Threat-model changes to §1 security-critical paths: who can reach this, with what, and what happens if they lie.

## 9. Errors, logging, and observability

Observability is part of the design, not a follow-up ticket. A change is not understood until you can say how its success and failure will show up in production.

- One error convention, followed everywhere. Expected failures (invalid input, limits, not found, conflicts) are typed, handled values that produce an actionable message. Unexpected failures propagate to the single error boundary the repo defines, are captured by the §1 error-tracking tool, and show the user a generic message.
- Never leak internal detail — stack traces, queries, vendor error strings, internal identifiers — into a user-facing message, a URL, or a public API response.
- Every catch either handles the error meaningfully or rethrows. An empty catch block is a bug. Never swallow errors to make a path "work".
- Structured logging with defined levels and correlation identifiers (request, user, job). Never log secrets, tokens, full request bodies, raw uploaded content, or personal data.
- Anything that runs unattended (job, cron, queue consumer) reports success and failure somewhere a human will see it, with a bounded retry policy.
- **Every new endpoint, job, external call, or queue consumer emits the baseline signals**: request or run count, error count, and latency, labelled consistently with the §1 observability tool's conventions. Reuse the existing instrumentation helpers; do not add a second metrics or logging library.
- **Trace across boundaries.** The correlation identifier is propagated through every process, network, and queue hop the change touches, so one request can be followed end to end.
- **Alerts follow user impact, not implementation detail.** Anything users or callers depend on has an alert on its symptom (error rate, latency, staleness, backlog) with an owner and a stated threshold; a metric nobody is alerted on or looking at is noise. Alert and dashboard definitions live in code (§13), next to the thing they observe.
- **Health and readiness** are exposed where the platform expects them and reflect real dependencies, not a hardcoded OK.
- **Budgets in §10 are measured, not assumed.** A change that claims a performance or cost property points at the metric that proves it.

## 10. Performance and cost

- Budgets are the §1 numbers. A change that risks a budget says so in the plan; a change that breaks one does not merge.
- No N+1 access patterns; check what a list actually executes. Every list, map, or export query is paginated and bounded — no unbounded reads of a whole table or bucket.
- Never process a resource at full fidelity when a smaller representation (a derivative, metadata, a projection) answers the question.
- Anything that fans out — batch jobs, queue producers, parallel requests — has a stated upper bound. Scheduled work runs as rarely as the requirement allows.
- Heavy dependencies load only where they are used; consider the footprint of every new dependency on bundle, binary, cold start, or memory.
- Cache deliberately, with a stated invalidation story; a cache without one is a bug you have not found yet.
- Metered resources (§1) are paid for by someone. If a change plausibly increases per-user or per-request cost, say so with a rough estimate.

## 11. User experience, accessibility, and public web surface

Apply the UX and accessibility items to anything a human interacts with — web, mobile, desktop, CLI, or API error messages. Apply the web-surface items where the project serves public pages.

- Loading, empty, error, and success states are all designed, not just the happy path. Long operations show real progress, never an indefinite spinner.
- Errors are actionable: tell the user what to do, not only that something failed. Destructive actions confirm; irreversible ones confirm harder and say what is lost.
- Keyboard reachable with a sane focus order and visible focus; screen-reader labels on interactive elements; contrast, touch-target size, and alt text meet the §1 accessibility target; motion respects the user's reduced-motion preference.
- Works at the §1 smallest supported viewport, not only on a large screen. Layout does not shift as content loads — media carries explicit dimensions.
- Public pages are server-rendered or statically generated, carry title, description, and canonical metadata, and social-sharing metadata where the page is shareable. Non-public content is excluded from indexing. Structured data where the page type supports it.
- URLs are stable and human-readable; a URL change is a breaking change and gets a redirect.
- User-facing strings are kept where they can be translated later, if the project will ever be localised; retrofitting is expensive.

## 12. Review checklist

Apply this **once**, at the review step in §3, in a fresh context. Report findings per dimension; if a dimension does not apply, say so in one line. This is a lens for the reviewer, not a ritual to repeat while implementing.

| Dimension | Ask |
|---|---|
| Correctness | Does every stated requirement have code and a test? Do failure paths behave as specified? Were assumptions made that the request did not state? |
| Scope (§4) | Does every changed line trace to the request? Anything added that was not asked for? |
| Simplicity (§5) | Is there a smaller solution? Any abstraction serving a case that does not exist? |
| Architecture (§6) | Fits the layering; dependencies point inward; boundaries explicit; no vendor import outside the boundary layer; contracts consistent; ADR written if expensive to reverse. |
| Tests (§7) | Right layers; failure paths; authorisation branches; deterministic; assertions meaningful. |
| Security (§8) | Input validated and authorisation checked at each boundary touched; no access-control bypass; no new attack surface unstated; secrets untouched. |
| Errors and observability (§9) | Expected failures as values; unexpected reach the boundary; nothing swallowed; nothing internal leaked; logs structured and clean; new endpoints, jobs, and external calls emit count, error, and latency signals; correlation ID propagated; failure of the change is covered by a named alert or is explicitly stated not to need one. |
| Performance and cost (§10) | Budgets respected; no N+1; bounded lists and fan-out; dependency footprint considered; cost impact stated. |
| UX and web surface (§11) | All states present; errors actionable; accessible; metadata and indexing correct for public pages. |
| Data and provisioning (§6, §13) | Migrations backward-compatible; rollback path stated; generated artefacts regenerated; IaC planned. |
| Docs and OSS (§13) | §13 obligations met; nothing internal or sensitive added; repo still publishable. |

## 13. Provisioning, git, docs, open source

### Provisioning
- Schema changes happen only through migrations: backward-compatible, expand/contract, never a manual change in any environment. Add before you use; remove one deploy after you stop using. Roll forward; do not write down-migrations for shared environments. `[ENFORCED: CI applies migrations to an empty database]`
- All infrastructure is code. Every resource the system depends on — compute, storage, networking, DNS, queues, secrets containers, monitoring, access policies, third-party service configuration where the vendor exposes an API — is defined in the §1 IaC tool and reproducible from an empty account with the bootstrap command. If a resource cannot be created by the tool, it is recorded in the manual-steps document with the reason and the exact steps; that document is the only permitted home for manual work.
- Infrastructure changes happen only through the IaC tool: plan/diff reviewed before apply, state remote and locked, never a manual console change. Drift is an incident: detect it, then reconcile by changing the code, never by editing the resource. `[ENFORCED: CI plan on every PR]`
- Environments are identical in shape and differ only in variables; no environment-specific branches in the infrastructure code.
- Risky rollouts — anything touching §1 security-critical paths or with no clean rollback — go behind a feature flag with a kill switch.

### Git
- Conventional commit messages; small PRs; branches follow the §1 pattern; changelog and version follow the §1 policy. `[ENFORCED: commit-msg lint]`
- Commit and push only when asked, and never directly on the default branch; open a pull request for review. Never force-push a shared branch. Never rewrite history that others have pulled. Never commit generated output that the build reproduces, unless §1 lists it as committed-and-regenerated. *(maqs adaptation: §1 *Git and CI* overrides the default-branch rule — direct to `main` when asked, solo-maintained.)*

### Writing for people
- Use the repository's templates when they exist — pull request template, issue templates, ticket templates — and fill every section; do not invent a different structure or leave template headings empty.
- Anything the user will post under their own name — PR descriptions and comments, tickets, review replies, team messages, changelog entries, release notes — is written in plain, conversational, concise English: short sentences, everyday words, the point first, no filler, no marketing tone, no headings or bullet cascades where two sentences would do. Run it through the prose skill named in §1 before handing it over.
- Say what changed, why, what to look at, and what is not done. Leave out narration of the process, self-praise, and hedging. A reader with no context should understand it in one pass.
- Match the register of the surrounding thread or repo; a one-line reply is often correct.

### Documentation
- **Maintain the §1 documentation suite.** It exists so that a contributor with zero context can understand how everything works and why. Every change that alters how something works — or makes an existing document wrong — updates that document in the same change. A new subsystem, pipeline, or integration gets a document or section before it is considered done. If a required document is missing for an area you touch, create it; if one is stale, fix it or flag it. Each document has the job the §1 table gives it; a fact lives in exactly one of them and is linked from the others.
- `README.md` is an overview and entry point that links out; it does not absorb. Beyond the suite, no noise documentation: no file-by-file narration, no restating what the code plainly says, no documenting behaviour that does not exist yet.
- Write an ADR (context, decision, consequences, rejected options and why) for any decision that is expensive to reverse.
- Exported or public functions carry a doc comment explaining why they exist and any non-obvious contract. Migrations carry a header stating what changes and why.
- Docs assume zero internal context: no references to conversations, tickets, or people that an outside contributor cannot see.

### Open source readiness
- The repository is public from day one and must stay publishable, without a cleanup sprint. Always present: `LICENSE` (Apache-2.0, code), `DATA_LICENSE.md` (data: ODbL and every provider attribution), `CONTRIBUTING.md`, `SECURITY.md` with a disclosure contact, `CODE_OF_CONDUCT.md`, issue and PR templates, and a README an outsider can follow with no tribal knowledge. (No `.env.example` — nothing reads the environment except CI's default token.) `[ENFORCED: CI presence check]`
- Nothing internal in the repository or its history: no real user data, internal URLs, account identifiers, dashboards, or personal notes — and nothing about the consuming apps. No dead experiments or throwaway files. Code, comments, commits, and docs are in English.

## 14. Hard rules

These override anything else, including an approved plan.

1. Never commit a secret (§8). If one is exposed, stop and report it; rotation comes before any other work. `[ENFORCED: secret scanning]`
2. Never run a destructive command against a shared environment — no destroy, reset, drop, or bulk delete. Here that means: never delete or overwrite a published data release or its assets by hand, never edit `config/sources.json` on `main` outside a reviewed change. Ask.
3. Never change a schema, an access policy, or infrastructure outside migrations and IaC (§13).
4. Never bypass an access-control mechanism to make something easier (§8).
5. Never disable, weaken, or skip a test, type check, or lint rule to make a check pass (§7). `[ENFORCED: CI on clean checkout]`
6. Never add a dependency or vendor silently (§4).
7. Never present a guess as fact (§2), and never claim something is tested, documented, or working when it is not. "This part is unverified" always beats a confident wrong claim.

## 15. Reporting and asking

- Ask when: the requirement is ambiguous and the interpretations lead to different designs; the simplest correct solution conflicts with the existing architecture; the change touches anything in §4's ask-before list; you would need a privileged credential to proceed; an existing test appears wrong; the §1 documentation and the code disagree; a tool disagrees with what you remembered. A question costs one message; a wrong assumption costs a rewrite.
- Report honestly. If something is half-finished, say which half. If you took a shortcut, name it. If a check was skipped, say so and why. Do not pad a summary to sound more thorough than the work was.
- When reporting a finished change, include: what changed and why, the commands run and their results, what was not done, and anything the reviewer should look at first.

## 16. Maintenance

This file is code. When Claude misbehaves, find the rule that allowed it and patch that rule — or, if the rule is one it keeps ignoring, move it into CI, pre-commit, or a hook where it cannot be ignored. When Claude already does something correctly without a rule, delete the rule. A new rule must earn its place: prefer patching an existing rule to adding one, and keep the §1 context sections rich. Review changes to this file like code. After a month of use, run `/doctor` and cut whatever it flags as already followed; decline its suggestions to remove §1 context that prevents mistakes.

When something in this codebase surprises you — a quirk, a trap, a behaviour the docs did not predict — add it to §1 *Things that will bite you* as part of the same change. When a domain term is used loosely and causes a wrong change, add it to §1 *Domain vocabulary*.

### What CI and pre-commit must back
- Pre-commit (to be added in Phase 1/4 as the matching code lands): `swift-format` or SwiftLint for Swift; `ruff check` + `ruff format --check` for the pipeline; a guard that rejects `.pmtiles`, `.sqlite`, `.pbf`, and anything under `dist/` or `.cache/`.
- CI on every push/PR, from a clean checkout: `swift.yml` — build and test on iOS Simulator and macOS with warnings as errors, plus an import check that `MapLibre` appears only under `Sources/MaqsUI/`; `build-maps.yml` (PR mode) — `test` region end to end, JSON Schema validation of `manifest.json` and `sources.json`, the 1.9 GiB asset check, checksums, `build-report.json`; OSS file presence.
- The rest of the template's enforcement list (secret scanning, dependency/licence scan, mutation testing, migration-apply, IaC plan) is aspirational here — add a check when it earns its place; until then the matching rules are judgment, not `[ENFORCED]`. Note that "migrations" and "IaC" in §13 reduce here to: `layer_schema_version` bumps with a documented compatibility rule, and the workflows themselves.
- Test files: changes reviewed deliberately; deletions or removed assertions require a stated reason in the commit.

### Stack customization

Everything below is maqs-specific engineering law. It has the same force as §14.

#### Locked technical decisions — do not relitigate (verify facts in Phase 0; stop and report if one is wrong)

| Concern | Decision |
|---|---|
| Basemap | **Shortbread 1.0** from **VersaTiles only** (ADR 0004). Online `tiles.versatiles.org/tiles/osm`; offline `versatiles convert --bbox … --compress gzip https://download.versatiles.org/osm-landcover.versatiles` — a remote range-request extract, never a planet download. gzip is mandatory: MapLibre rejects brotli PMTiles |
| Terrain | **Terrarium** DEM from **VersaTiles only**: the Mapterhorn build, 512 px WebP, z0–12. Online `tiles.versatiles.org/tiles/elevation`; offline `versatiles convert --bbox … https://download.versatiles.org/elevation.versatiles`. One encoding, one Swift decode path (ImageIO). Attribution: Mapterhorn plus its DEM sources |
| OSM source | Geofabrik `europe/italy/nord-est` PBF, downloaded once per run, then `osmium extract` per region |
| Trails | **Source adapters** emitting one normalised record with provenance (ADR 0006); sources per region in `regions.yaml`, merged by priority with `ref` + overlap dedupe. Adapter 1 (only one shipped): OSM `route=hiking` relations assembled by our own pyosmium step from the uncut nord-est file, keeping `ref`, `ref:REI`, `name`, `cai_scale`, `sac_scale`, `network`, `operator`, `osmc:symbol`, `from`, `to`, `roundtrip`, `survey:date`, `website`. Planned: Alpenverein Südtirol, SAT, regional networks, each with a source ADR. `ascent_m`/`descent_m` from **our own** terrain data |
| Places | peaks, volcanoes, saddles, `mountain_pass=yes`, alpine/wilderness huts, shelters, named village/hamlet/isolated_dwelling; names `name`, `name:it`, `name:de`, `name:fur`, `name:sl`; `ele`, `wikidata`; `rank_score` simple and documented |
| Curvature | **Our own Python step** (ADR 0005): three-point-circle radius per segment, `curvature`-compatible bands and per-way score, plus the `corners` table (apex, min radius, direction, entry/exit). No GPL tool in the pipeline |
| Distribution | per-region files + `manifest.json` in a GitHub Release `data-YYYY-MM`, marked latest; clients use `releases/latest/download/manifest.json`; **never the REST API** |
| Rendering | MapLibre Native iOS via SPM, pinned `6.31.0` (`< 7.0.0`), **iOS/iPadOS only** (ADR 0003); local PMTiles via `pmtiles://file://…`; hillshade yes, 3D terrain no. No MapLibre offline packs |
| Storage | SQLite with **FTS5** (unicode61, `remove_diacritics`) and **R\*Tree** on the system library — a Phase 0 verification item; one geometry encoding chosen by ADR |
| Package | Swift 6, strict concurrency, iOS 18+ for all four products, macOS 15+ additionally for `MaqsCore`/`MaqsData`/`MaqsTerrain`; DocC on the public API, Swift Testing; `MaqsUI` is the only MapLibre importer; everything else system frameworks only |
| Pipeline | Python managed by `uv`, `uv run maqs build --region <id> [--layers …]`; pinned CLIs via `pipeline/bootstrap.sh`; idempotent steps; `.cache/` inputs, `dist/<region>/` outputs; `test` region < 5 min |
| Hosting | GitHub only: git for code, Releases for data, Actions for compute. No LFS, no buckets, no servers, no keys. Assets < 1.9 GiB (CI-enforced) |
| Config | `config/sources.json` (online providers, fetched from `main`, cached, bundled fallback) and `config/regions.yaml` (regions), both JSON-Schema-validated in CI. No provider URL in Swift logic |
| Licensing | code under **Apache-2.0** (`LICENSE`); data under ODbL with every attribution in `DATA_LICENSE.md`; every added dependency or provider states its licence in the ADR |

#### Swift package rules
1. **Products are independent by design.** An app that needs only elevation depends on `MaqsTerrain` alone and never links MapLibre. A cross-module convenience that would force a second product into every app is rejected.
2. **`MaqsUI` builds the style at runtime** from the app-supplied style JSON, `sources.json` online sources, and local PMTiles for installed regions; the switching strategy (local for installed bboxes, online elsewhere, `NWPathMonitor` reactions) is an ADR before implementation and a section in `docs/architecture.md` after. The package's default style is a **muted, light-and-dark Shortbread style** with a documented palette and an accent colour the app passes in; it is the one renderer for online and offline alike (decided 2026-10-07 — no MapKit anywhere in this package).
3. **Offline means offline.** Glyphs and sprite ship in the package bundle (one open font family, regular and bold, licence included); styles reference the local copies when offline. A style that still needs the network inside an installed region is a bug.
4. **Provider etiquette is code.** App-identifying User-Agent on MapLibre's network configuration and on every URLSession this package creates; never a no-cache header; HTTP caching on. The attribution view always shows the credits of the *active* sources.
5. **Downloads are background `URLSession`, resumable, SHA-256 verified, atomically installed, excluded from iCloud backup**, with install and download state observable from SwiftUI. The app declares the layers it needs; nothing else is fetched.
6. **Readers are read-only and tolerant.** `MaqsData` opens any installed region's SQLite read-only, returns typed empty results when nothing is installed, and never writes. Query APIs stay simple (bbox, FTS, id, bearing corridor, corners ahead); map-matching is not this package's job.
7. **The PMTiles reader is minimal and defensive.** Header, directories, varints, gzip via Compression — bounds-checked everywhere; no feature beyond what `MaqsTerrain` needs.
8. **Terrain API is identical for local packs and online tiles**, with a bounded in-memory LRU for online tiles. Profile sampling exposes earth-curvature and refraction corrections as parameters, not constants.
9. **No app knowledge.** No app name, bundle id, style, or feature flag in `Sources/`. The demo app is the only consumer in this repo and it is deliberately boring.

#### Pipeline rules
1. **Reuse, don't build — unless the tool is dormant.** `versatiles`, `osmium`, `tippecanoe` do the heavy lifting; Python orchestrates, validates, and computes what no maintained tool provides (trail assembly and merge, `rank_score`, ascent/descent, curvature and corners, the manifest). Rendering tiles ourselves is out of scope.
2. **Idempotent and cached.** Every step checks its inputs in `.cache/` and its outputs in `dist/<region>/` before doing work; a re-run with nothing changed does nothing.
3. **Pinned and reproducible.** Every CLI version is pinned in `pipeline/bootstrap.sh` and works on macOS and `ubuntu-latest`; `uv.lock` is committed.
4. **Validate before publishing.** Size limit, row-count sanity against Phase 0 numbers, SHA-256, schema validation, `build-report.json` — all before `gh release`. A validation failure fails the job; a data anomaly is reported and the build continues.
5. **Every SQLite output carries the `metadata` table** and uses FTS5/R*Tree per `docs/data-format.md`; every format change bumps `layer_schema_version` and documents the compatibility rule.
6. **One region = one `regions.yaml` entry.** The matrix, the manifest, the release, and the docs all derive from it; adding a region touches nothing else.

#### CI and release rules
- `build-maps.yml`: monthly cron + `workflow_dispatch` (optional `region`, `layers`); a download job shares the Geofabrik PBF via artifact or cache; a matrix job per region from `regions.yaml`; a final job assembles `manifest.json`, creates or updates the `data-YYYY-MM` release with `gh`, uploads assets, marks latest. Free disk space first. Pin action versions. Re-running a month replaces assets. Only `GITHUB_TOKEN`.
- `swift.yml`: build and test on macOS runners for iOS Simulator and macOS using the `test` region fixtures; `paths` filters so data-only and docs-only changes do not spend macOS minutes.

#### What NOT to do
- Don't reference the consuming apps, anywhere, for any reason.
- Don't add a Swift package other than MapLibre, or import MapLibre outside `MaqsUI`.
- Don't hardcode a provider URL in Swift; it goes in `config/sources.json`.
- Don't call `api.github.com` from client code, ever.
- Don't download the planet, commit generated data, use LFS, or upload a release asset by hand.
- Don't send no-cache headers or a generic User-Agent to any provider.
- Don't fail a monthly build on bad OSM data — flag it in the report and keep going; do fail it on a size, checksum, or schema violation.
- Don't start the next phase without the go-ahead the brief requires.
- Don't invent a URL, licence term, version, or capability for a provider or tool — verify it live and record it in `docs/decisions.md`.
