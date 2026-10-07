# Decisions

Architecture decision records for maqs, newest at the bottom. Each entry is short: context, decision, consequences, and anything it contradicts in `BRIEF.md`. Facts were verified against live sources on the date given; re-verify before relying on a number that is more than a few months old.

Status values: **accepted**, **proposed** (needs the owner's go-ahead), **superseded by NNNN**.

---

## 0001 — Phase 0 verification of the brief's locked decisions

**Date:** 2026-10-07 · **Status:** accepted (findings) · **Scope:** every item under "Decisions already made" in `BRIEF.md`.

Everything was checked against the live source on 2026-10-07 (web pages, GitHub APIs, release assets, and local runs on this machine: macOS 27, Xcode 27, iOS 27 simulator, Swift 6.4). Items marked **CONTRADICTS BRIEF** need an owner decision before the phase that depends on them.

### Basemap (brief item 1)

| Fact | Verified value | Source |
|---|---|---|
| VersaTiles public server | `https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}`, TileJSON at `/tiles/osm/tiles.json`, `tile_schema: shortbread@1.0`, max zoom 14 | tiles.versatiles.org/tiles/osm/tiles.json; docs.versatiles.org/guides/use_tiles_versatiles_org.html |
| VersaTiles terms | A demo server: "free and open to everyone, but it comes without any guarantees"; per-IP rate limit (unpublished number, 429 without Retry-After); `Cache-Control: public, max-age=21600`; no ETag/Last-Modified, so every revalidation is a full download; "If you rely on a stable map server, we highly recommend hosting it yourself" | same guide |
| VersaTiles hosted `osm` is **OSM + ESA WorldCover landcover** (beta) | Required attribution: `© OpenStreetMap contributors` (ODbL) **and** `CC BY 4.0 ESA WorldCover 2021` | TileJSON `attribution`; docs.versatiles.org/basics/tilesets.html |
| VersaTiles planet download | `https://download.versatiles.org/osm.versatiles`, 66,534,652,244 bytes (62.0 GB), `Accept-Ranges: bytes`, Shortbread 1.0, OSM data of 2026-06-07 (planetiler build 2026-06-18). Dated builds roughly **quarterly** (20240101 … 20260608); `osm.versatiles` always points at the newest; pin a dated file for reproducibility | download.versatiles.org; feed-osm.xml; `versatiles probe` of the remote file |
| `versatiles convert --bbox … <https URL> out.pmtiles` is a remote range-request extract | **Measured:** test bbox (12.23,46.09,12.27,46.12) 26 tiles z0–14, 1.09 MB in 7.7 s; Veneto bbox 19,235 tiles z0–14, **238 MB in 29 s**. No planet download | local run, versatiles 5.0.0 |
| versatiles CLI | v5.0.0 (released 2026-10-04). macOS: `brew tap versatiles-org/versatiles && brew install versatiles` (installed here). Ubuntu: `.deb` and tarballs in the GitHub release, `install-unix.sh`, or `cargo install versatiles` | github.com/versatiles-org/versatiles-rs/releases |
| OSMF vector tiles | `https://vector.openstreetmap.org/shortbread_v1/{z}/{x}/{y}.mvt`, TileJSON at `/shortbread_v1/tilejson.json`, serving **Shortbread 1.1** since 2026-08-25 under the same `shortbread_v1` path; not marked experimental; `cache-control: max-age=300, stale-while-revalidate=3600` | vector.openstreetmap.org; community.openstreetmap.org/t/now-serving-shortbread-1-1-tiles/146864 |
| OSMF usage policy (operations.osmfoundation.org/policies/vector/) | Verbatim requirements: bulk downloading "is prohibited"; "Valid HTTP User-Agent identifying application. Faking another app's User-Agent WILL get you blocked. Using a library's default User-Agent is NOT recommended"; no `no-cache` headers; cache tiles per the Expiry header or at least 7 days; "Clearly display license attribution, normally in the bottom-right corner"; "Recommended: Do not hardcode any URL to vector.openstreetmap.org … switching should be possible without requiring a software update"; recommended contact email on the app store page; old tiles kept one month with updates plus two months without after a new major Shortbread version; "access may be withdrawn at any point" | policy page, fetched 2026-10-07 |
| Shortbread schema | 1.0 and 1.1 published, 1.2 draft; "A style written for version X.Y of the schema should work on any tilesets with the same MAJOR version and an equal or greater MINOR version". VersaTiles serves 1.0, OSMF serves 1.1 — same MAJOR, so a **1.0 style** works on both; 1.1-only fields (`name_xx`, access attributes) are absent on VersaTiles | shortbread-tiles.org/schema/versioning/ |

**CONTRADICTS BRIEF (minor):** the brief says both online providers "serve the same schema". They serve the same *major* version only. Decision: pin the manifest's `shortbread_version` to **1.0** and write the default style against 1.0.

**New constraint:** MapLibre Native reads PMTiles with `tile_compression` **gzip or none only**; brotli and zstd throw "Compression method not supported" (`pmtiles_file_source.cpp`, ios-v6.31.0). VersaTiles writes **brotli** by default, so the pipeline must pass `--compress gzip`. Measured cost on the test region: 1,086,226 → 1,150,240 bytes (+6 %).

**Observation:** the VersaTiles planet is roughly quarterly and currently four months behind OSM. A monthly `data-YYYY-MM` release will often ship the same basemap as the previous month while trails, places, and curvature move with Geofabrik's daily extract. Acceptable; the manifest records the basemap's `osm_timestamp` separately.

### Terrain (brief item 2)

| Fact | Verified value | Source |
|---|---|---|
| AWS Open Data Terrain Tiles | `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`, zoom 0–15, served today (HTTP 200, `Accept-Ranges`), but tiles carry `Last-Modified` **Nov/Dec 2017**: effectively frozen | registry.opendata.aws/terrain-tiles/; live HEAD requests; tilezen/joerd docs/use-service.md |
| Terrarium decoding | `(red * 256 + green + blue / 256) - 32768`, metres | tilezen/joerd docs/formats.md |
| Attribution | The brief's "Mapzen, USGS, NASA SRTM, EEA" is wrong. The required text is the full list in tilezen/joerd `docs/attribution.md` (ArcticDEM/NSF, Geoscience Australia, Austria DGM, Canada OGL, Copernicus EU-DEM, NOAA ETOPO1, INEGI, LINZ, Kartverket, UK Environment Agency, USGS 3DEP/GMTED2010/SRTM) plus Mapzen for the hosted service; copy it verbatim into `DATA_LICENSE.md` | github.com/tilezen/joerd/blob/master/docs/attribution.md |
| Protomaps "terrarium-z12.pmtiles (preview)" | Exists at `https://r2-public.protomaps.com/protomaps-sample-datasets/terrarium-z12.pmtiles`: 159.8 GB, z0–12, 256 px PNG, `Last-Modified` 2023-02-21, scraped from the AWS tiles, no `attribution` key, **no longer linked from the Protomaps docs** (removed in favour of Mapterhorn). A sample under a "sample-datasets" path with no update cadence | github.com/orgs/protomaps/discussions/22; docs.protomaps.com/basemaps/downloads |
| Mapterhorn (what Protomaps now links) | `https://download.mapterhorn.com/planet.pmtiles`: z0–12, 355.6 GB, `Last-Modified` 2026-09-11, **512 px WebP terrarium**, attribution `© Mapterhorn` plus per-source credits in `https://download.mapterhorn.com/attribution.json` (151 sources; for our area: TINITALY 10 m INGV CC BY 4.0, Trentino LiDAR 5 m CC BY 2.5, Bolzano 2.5 m CC0, Slovenia 1 m CC BY 4.0, Austria 1 m CC BY 4.0, Copernicus GLO-30). Zoom 13–17 in regional archives named by z6 tile (`6-34-22.pmtiles` covers the test region) | mapterhorn.com/data-access/; attribution.json; live HEAD |
| `pmtiles extract` from a remote archive is a range-request extract | **Measured, test bbox z0–12:** Protomaps sample 13 tiles, 1.0 MB; Mapterhorn 13 tiles, 2.4 MB, both ~1–2 s. **Veneto bbox z0–12:** Protomaps sample **45 MB in 10 s**; Mapterhorn **105 MB in 5 s** (1,331 tiles). Mapterhorn z13–15 for the whole Veneto bbox would be ~2.7 GB across four regional archives (dry-run), i.e. above the asset limit as one file | local runs, pmtiles 1.31.2 |
| pmtiles CLI | v1.31.2 (2026-07-22); `brew install pmtiles` (installed); Linux release tarball `go-pmtiles_1.31.2_Linux_x86_64.tar.gz`. Flags: `--bbox`, `--region`, `--minzoom`, `--maxzoom`, `--download-threads`, `--dry-run`, `--overfetch`. Source must be clustered (both candidates are) | docs.protomaps.com/pmtiles/cli; go-pmtiles main.go |
| PMTiles v3 spec | 127-byte header; varint directories (delta tile ids, run lengths, lengths, offsets); compression enum 0 unknown / 1 none / 2 gzip / 3 brotli / 4 zstd; tile types 1 MVT, 2 PNG, 3 JPEG, 4 WebP, 5 AVIF, **6 MapLibre Vector Tile** (new); header + root directory ≤ 16,384 bytes | github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md |
| MapLibre and WebP DEM | On Darwin, raster-dem tiles decode through ImageIO, which decodes WebP since iOS 14 / macOS 11; `encoding: terrarium` is parsed; **hillshade is supported, 3D terrain is not** (maplibre-native #252) | `raster_dem_tile_worker.cpp`, `image.mm` at ios-v6.31.0; maplibre.org/maplibre-style-spec/terrain/ |

**CONTRADICTS BRIEF:** the Protomaps terrarium file the brief names is an unmaintained 2023 sample that Protomaps has already de-listed. See ADR 0002 for the proposed replacement.

### OSM source data (brief item 3)

| Fact | Verified value | Source |
|---|---|---|
| Geofabrik nord-est | `https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf` (HTTP redirect since 2025-09-01: use `curl -L`), rebuilt daily ~21:00 CET. **Measured:** 624,844,779 bytes, downloaded in 19 s; data up to 2026-10-06T20:21:06Z; 71.9 M nodes, 8.2 M ways, 128 k relations | download.geofabrik.de/europe/italy/nord-est.html; local run |
| Geofabrik politeness | No numeric limit; a 2025-09-10 blog post asks for no piecemeal planet downloads, monitored scripts, and `pyosmium-up-to-date` for refreshes; abusive IP ranges get blocked. One download per monthly run is well within this | blog.geofabrik.de/index.php/2025/09/10/download-responsibly/ |
| osmium-tool | 1.19.1 (Homebrew, installed). Ubuntu 24.04 apt ships only **1.16.0**; `bootstrap.sh` must take a newer path on Linux (build from source or a prebuilt). `osmium tags-filter` adds referenced members **by default** (there is no `-r`; `-R` omits them). `osmium export` assembles only multipolygon and boundary relations: **route relations are not exported as linestrings**, only their member ways with the ways' own tags | docs.osmcode.org/osmium/latest/; local run |
| Per-region cut by admin polygon | Veneto, Friuli-Venezia Giulia, and Trentino-Alto Adige/Südtirol `admin_level=4` boundaries extracted from the PBF itself and used as `osmium extract --polygon`. **Measured:** Veneto 242.7 MB in 10.4 s; FVG 82.6 MB in 6.1 s; TAA 113.4 MB in 6.8 s; test bbox 173 kB in 3.5 s. Derived bboxes: Veneto 10.6231,44.7923,13.1021,46.6806; FVG 12.3214,45.5809,13.9187,46.6480; TAA 10.3818,45.6729,12.4780,47.0921 | local runs |
| tippecanoe | felt/tippecanoe 2.79.0 (Homebrew, installed); writes PMTiles directly with `-o out.pmtiles` (verified on the test trails: gzip-compressed MVT, z0–11). Ubuntu apt has 2.49.0; build from source on Linux | local run; github.com/felt/tippecanoe |

### Trails (brief item 4)

| Fact | Verified value | Source |
|---|---|---|
| CAI–Wikimedia Italia agreement | Signed 2016-10-08, renewed Feb 2021 and Feb 2024. Mandatory relation tags: `type=route`, `route=hiking`, `network=lwn/rwn/nwn/iwn`, `ref`, `source`, `cai_scale`; relevant: `operator`, `name`, `ref:REI`, `osmc:symbol`, `source:ref`. `cai_scale` values: T, E, EE, EEA (with `:F`, `:PD`, `:D`, `:MD`, `:ED`), EAI. OSM2CAI: `https://osm2cai.cai.it/` | wiki.openstreetmap.org/wiki/IT:CAI; Key:cai_scale |
| `osmItalia/cai_scripts` (`caiosm`) | GPL-3.0, Overpass-driven, 2020-pinned dependencies, last commit 2021-06. **Decision: do not reuse.** Its tag conventions are the useful part | github.com/osmItalia/cai_scripts |
| Coverage counts (relations with `route=hiking` inside the admin polygon) | **Veneto** 1,955 relations: 1,199 with `cai_scale` (61 %), 1,663 with `ref` (85 %), 1,148 with both, 1,641 with `osmc:symbol`. **Friuli-Venezia Giulia** 1,271: 760 `cai_scale` (60 %), 917 `ref` (72 %), 690 both, 951 `osmc:symbol`. **Trentino-Alto Adige** 5,794: 1,477 `cai_scale` (25 %), 4,954 `ref` (86 %), 1,432 both, 4,903 `osmc:symbol`. `cai_scale` distribution is dominated by E, then T/EE, with a few dozen EEA variants per region. **Test bbox:** 3 relations | local runs on the 2026-10-06 extract |
| Relation completeness | Route relations cross region borders. After the polygon cut, **10.5 %** of Veneto hiking relations are missing at least one member way; even in the uncut nord-est file **5.1 %** are incomplete (members outside nord-est). Veneto has 39 superroutes (relation members) | `osmium check-refs -r` and a pyosmium count |

**Design consequence (Phase 1):** trail geometry must be assembled by our own small pyosmium step (ordered merge of member ways, gap/reversal detection, flagging), reading relations from the **uncut nord-est file** and assigning them to regions by intersection, not from the clipped region PBF. Incomplete relations are flagged in `build-report.json`, never dropped silently, as the brief requires.

### Places (brief item 5)

Quick count on the Veneto polygon with the brief's tag set (`natural=peak|volcano|saddle`, `mountain_pass=yes`, `tourism=alpine_hut|wilderness_hut`, `amenity=shelter`, `place=village|hamlet|isolated_dwelling`, nodes only): **13,408** nodes, 5,509 with `wikidata` (41 %), 4,261 with `ele` (32 %). Enough signal for the `rank_score` formula to use both inputs; the formula itself is a Phase 1 ADR.

### Road curvature (brief item 6)

| Fact | Verified value | Source |
|---|---|---|
| Licence | GPL **v3 or later**, stated in the README only (no LICENSE file, so GitHub shows none). Running it in the pipeline and distributing only its output is fine; its code is never vendored into this repo or linked into the package | github.com/adamfranco/curvature README |
| Maintenance | Last commit 2022-01-12; "tested on Python 3.5"; depends on the deprecated `msgpack-python` and pyosmium | repo API; README |
| Does it still run? | **Yes, with two dependency fixes.** `uv tool install` fails (no console entry points: the tools are scripts in `bin/`). From a clone with Python 3.12, `osmium` 4.3.1, `msgpack<1` (the scripts pass the removed `encoding=` argument) and `geojson`, the `adams_default.sh` chain (`curvature-collect | curvature-pp add_segments | add_segment_length_and_radius | add_segment_curvature | filter_segment_deflections | split_collections_on_straight_segments | roll_up_length | roll_up_curvature | filter_collections_by_curvature --min 300 | curvature-output-geojson`) produced 19 features for the test bbox in 1 s and **24,403 features (45 MB GeoJSON) for Veneto in 169 s** | local run |
| What it gives us | Per-way curvature score and length, and per-segment length/radius inside its MessagePack stream (`curvature-pp add_segment_length_and_radius`). The `corners` table (apex, minimum radius, direction, entry/exit) is **not** produced by it; we derive it from the segment radii or from the way geometry ourselves | README; stream inspection |

**Decision:** use `curvature` as a pinned-commit, patched tool installed by `bootstrap.sh` (clone at commit `140907ba`, Python 3.12 venv, `osmium`, `msgpack<1`, `geojson`), not as a pip dependency. If the patches grow beyond the two above, fall back to the brief's alternative: a minimal Python implementation, documented here.

### Distribution and CI (brief item 7)

| Fact | Verified value | Source |
|---|---|---|
| Release assets | "Each file included in a release must be under 2 GiB"; no limit on total release size or bandwidth; up to 1,000 assets per release | docs.github.com/…/about-releases |
| `releases/latest/download/<asset>` | "the most recent non-prerelease, non-draft release, sorted by the `created_at` attribute", and `created_at` is the **tagged commit's date**, not the publish date. Consequence: after a re-run, call `gh release edit <tag> --latest` explicitly | docs.github.com/…/linking-to-releases; REST docs |
| Unauthenticated REST limit | 60 requests/hour. Release-download redirects and raw.githubusercontent.com have no published numeric limit (a May 2025 changelog says unauthenticated raw downloads are throttled, no figures). Clients still never call the API | docs.github.com/…/rate-limits-for-the-rest-api |
| Actions | Free on standard runners for public repos. `ubuntu-latest` = Ubuntu 24.04, 4 vCPU / 16 GB, ~20 GB free at job start (`jlumbroso/free-disk-space` reclaims up to ~31 GB). `macos-latest` = macOS 26 arm64, 3 vCPU / 7 GB. Cache 10 GB per repo; artifacts have no documented per-file cap. Release job needs `permissions: contents: write` | docs.github.com; actions/runner-images |
| `gh` | v2.102.0: `gh release create <tag> --latest`, `gh release upload <tag> <files> --clobber` ("Delete and re-upload existing assets of the same name"), `gh release edit <tag> --latest` all exist | cli.github.com/manual |

### Rendering (brief item 8)

| Fact | Verified value | Source |
|---|---|---|
| MapLibre Native iOS | Current stable **ios-v6.31.0** (2026-09-11); SPM `https://github.com/maplibre/maplibre-gl-native-distribution`, product `MapLibre`; xcframework `MinimumOSVersion` 12.0. A `7.0.0-pre0` prerelease raises the minimum to iOS 15.5. Pin `6.31.0` with an upper bound `< 7.0.0` | distribution Package.swift; release assets |
| `pmtiles://file://…` | Supported since **6.10.0** ("Add support for PMTiles with `pmtiles://` URL scheme"); works for vector, raster and raster-dem sources | MapLibre iOS docs, PMTiles page; CHANGELOG |
| Offline packs / ambient cache | Offline packs still unsupported for PMTiles sources. **Changed since the brief:** an ambient cache for remote PMTiles sources shipped in 6.27.0 (#4290); the docs' "no caching" note is stale. Our design (own downloaded PMTiles) stands | PMTiles.md; PR #4290 |
| User-Agent | `MLNNetworkConfiguration.sharedManager.sessionConfiguration.HTTPAdditionalHeaders["User-Agent"]`, set before any `MLNMapView` or `MLNOfflineStorage` exists; applies to every HTTP resource (tiles, style, TileJSON, glyphs, sprites, remote PMTiles). Background sessions are not supported there | `MLNNetworkConfiguration.h`, `http_file_source.mm` |
| Glyphs and sprites offline | `file://` and bundle (`asset://`) URLs are routed to local file sources for every resource kind | `MLNMapView.h`, `local_file_source.cpp` |
| **macOS** | **CONTRADICTS BRIEF.** The SPM binary is **iOS-only** (device and simulator slices, no macOS, no Catalyst slice). MapLibre's AppKit build is source-only, "mostly used for development", minimum macOS 14.3, not actively maintained | xcframework `Info.plist`; maplibre.org/maplibre-native/docs/book/platforms/macos/ |

See ADR 0003 for the macOS question.

### SQLite on Apple platforms

`PRAGMA compile_options` and a functional FTS5 (`unicode61 remove_diacritics 2`) + R\*Tree probe, compiled against the system `libsqlite3`:

| Where | SQLite | FTS5 | R\*Tree | JSON |
|---|---|---|---|---|
| macOS 27 (this machine), deployment target 15.0 | 3.54.0 | yes | yes | yes |
| iOS 27 simulator, deployment target 18.0 | 3.54.0 | yes | yes | yes |

iOS 18 and macOS 15 runtimes are not installed here; the public record (community compile-option tables) shows FTS5 since iOS 11.4 and R\*Tree since at least iOS 10, and Apple has never removed either. `SQLITE_OMIT_LOAD_EXTENSION` is set, so no loadable extensions. **Decision: FTS5 and R\*Tree on the system library are safe to build on.** Re-run the probe on an iOS 18 simulator before the first package release if one is installed by then.

### Pipeline timings on this machine (Apple Silicon, home fibre)

| Step | Test region | Veneto |
|---|---|---|
| Geofabrik nord-est download (625 MB) | shared | 19 s |
| `osmium extract --polygon` | 3.5 s (bbox) | 10.4 s |
| Basemap `versatiles convert` from remote planet (z0–14) | 7.7 s, 1.1 MB | 29 s, 238 MB |
| Terrain `pmtiles extract` z0–12 (Mapterhorn / Protomaps sample) | ~1 s, 2.4 MB / 1.0 MB | 5 s, 105 MB / 10 s, 45 MB |
| `osmium tags-filter r/route=hiking` | <1 s | ~2 s |
| `curvature` chain (Python 3.12) | 1 s, 19 features | 169 s, 24,403 features |
| `tippecanoe` trails overlay | <1 s, 7.7 kB | not measured |

The test region's 5-minute budget is met with a wide margin; the dominant cost per real region is network, not CPU. The `curvature` chain is the only CPU-bound step and the slowest per region; it is single-threaded Python.

**Test region note:** the bbox around Nevegal (12.23,46.09,12.27,46.12, ~10 km²) holds only 3 hiking relations. Phase 1 may widen it slightly so the fixtures exercise more than a trivial trail set while staying under a few MB.

---

## 0002 — Terrain source: Mapterhorn instead of the Protomaps terrarium sample

**Date:** 2026-10-07 · **Status:** proposed

**Context.** The brief's offline terrain source, `terrarium-z12.pmtiles (preview)`, is a 2023 scrape of the (2017-frozen) AWS terrain tiles that Protomaps hosts as a sample and no longer links. Protomaps' docs now point to Mapterhorn, a maintained terrarium-encoded PMTiles build (planet z0–12, updated 2026-09) assembled from national open DEMs with per-source attribution; for north-east Italy that means TINITALY 10 m, Trentino 5 m LiDAR, Bolzano 2.5 m, Slovenia 1 m, Austria 1 m, instead of 30 m-class SRTM/EU-DEM. Tiles are 512 px WebP rather than 256 px PNG, which doubles the Veneto z12 extract (105 MB vs 45 MB) but quadruples the pixels per tile.

**Decision (proposed).** Offline terrain comes from `https://download.mapterhorn.com/planet.pmtiles` at z0–12. Online terrain stays the AWS terrarium PNG tiles (z0–15, frozen but free and reliable), so the two paths differ in resolution and container format but share the terrarium encoding. The Swift sampler decodes both through ImageIO (WebP needs iOS 14+, far below our iOS 18 floor), so the "one code path" requirement holds at the pixel level. `DATA_LICENSE.md` carries both the Joerd attribution text and Mapterhorn's `© Mapterhorn` plus the per-source credits for the sources that intersect our regions.

**Rejected.** (a) The Protomaps sample: unmaintained, could vanish, no attribution metadata, older and coarser data. (b) Mapterhorn z13–15 for whole regions: ~2.7 GB for Veneto, over the asset limit; could become an optional `terrain-hd` layer per z6 archive later. (c) Serving terrain online from Mapterhorn's planet file via range requests: possible in MapLibre, but it is a download server, not a tile server, and the brief's online source is AWS.

**Consequences.** `MaqsTerrain` must decode WebP and PNG; the PMTiles reader accepts tile type 4 (WebP) and 2 (PNG). The brief's "same encoding" promise is kept; the "same source" assumption is not, and should be amended in `BRIEF.md`.

---

## 0003 — `MaqsUI` and macOS

**Date:** 2026-10-07 · **Status:** proposed (owner decision required)

**Context.** The brief targets iOS 18+ and macOS 15+ for the whole package and makes `MaqsUI` the MapLibre wrapper. MapLibre's SwiftPM distribution ships an iOS-only xcframework (no macOS or Catalyst slice). The AppKit port exists in the source tree but is documented as a development aid, minimum macOS 14.3, not actively maintained, and would have to be built from source in CI and shipped as our own binary.

**Options.**
1. **`MaqsUI` is iOS/iPadOS-only; `MaqsCore`, `MaqsData`, `MaqsTerrain` stay cross-platform.** A macOS app gets data, downloads, queries and elevation from maqs but renders maps some other way (MapKit for display, or a Catalyst build of the iOS app). Smallest change, no unmaintained dependency.
2. **Mac Catalyst.** The iOS xcframework has no Catalyst slice either; it would need verification that MapLibre builds for Catalyst at all. Untested; likely the same source-build burden as option 3.
3. **Build MapLibre for macOS from source** in `swift.yml` and vendor the resulting xcframework. Weeks of toolchain work against an unmaintained target; contradicts "reuse, don't build" and the one-dependency rule.

**Recommendation.** Option 1, with `Package.swift` declaring `MaqsUI` for iOS only and a note in the README. Revisit if MapLibre ships a macOS slice (7.x does not announce one).

**Consequences.** The brief's "Rendering" decision is amended: MapLibre renders on iOS and iPadOS; macOS rendering is out of this package's scope. The demo app is iOS-only. The design-system follow-ups recorded for Phase 4 (attribution slot, label font, hillshade) are unchanged; 3D terrain is off the table entirely since MapLibre Native does not implement it.
