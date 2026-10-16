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

**Date:** 2026-10-07 · **Status:** superseded by 0004 (same data, obtained through VersaTiles)

**Context.** The brief's offline terrain source, `terrarium-z12.pmtiles (preview)`, is a 2023 scrape of the (2017-frozen) AWS terrain tiles that Protomaps hosts as a sample and no longer links. Protomaps' docs now point to Mapterhorn, a maintained terrarium-encoded PMTiles build (planet z0–12, updated 2026-09) assembled from national open DEMs with per-source attribution; for north-east Italy that means TINITALY 10 m, Trentino 5 m LiDAR, Bolzano 2.5 m, Slovenia 1 m, Austria 1 m, instead of 30 m-class SRTM/EU-DEM. Tiles are 512 px WebP rather than 256 px PNG, which doubles the Veneto z12 extract (105 MB vs 45 MB) but quadruples the pixels per tile.

**Decision (proposed).** Offline terrain comes from `https://download.mapterhorn.com/planet.pmtiles` at z0–12. Online terrain stays the AWS terrarium PNG tiles (z0–15, frozen but free and reliable), so the two paths differ in resolution and container format but share the terrarium encoding. The Swift sampler decodes both through ImageIO (WebP needs iOS 14+, far below our iOS 18 floor), so the "one code path" requirement holds at the pixel level. `DATA_LICENSE.md` carries both the Joerd attribution text and Mapterhorn's `© Mapterhorn` plus the per-source credits for the sources that intersect our regions.

**Rejected.** (a) The Protomaps sample: unmaintained, could vanish, no attribution metadata, older and coarser data. (b) Mapterhorn z13–15 for whole regions: ~2.7 GB for Veneto, over the asset limit; could become an optional `terrain-hd` layer per z6 archive later. (c) Serving terrain online from Mapterhorn's planet file via range requests: possible in MapLibre, but it is a download server, not a tile server, and the brief's online source is AWS.

**Consequences.** `MaqsTerrain` must decode WebP and PNG; the PMTiles reader accepts tile type 4 (WebP) and 2 (PNG). The brief's "same encoding" promise is kept; the "same source" assumption is not, and should be amended in `BRIEF.md`.

---

## 0003 — `MaqsUI` and macOS

**Date:** 2026-10-07 · **Status:** accepted (owner, 2026-10-07: maqs is mobile-first; option 1)

**Context.** The brief targets iOS 18+ and macOS 15+ for the whole package and makes `MaqsUI` the MapLibre wrapper. MapLibre's SwiftPM distribution ships an iOS-only xcframework (no macOS or Catalyst slice). The AppKit port exists in the source tree but is documented as a development aid, minimum macOS 14.3, not actively maintained, and would have to be built from source in CI and shipped as our own binary.

**Options.**
1. **`MaqsUI` is iOS/iPadOS-only; `MaqsCore`, `MaqsData`, `MaqsTerrain` stay cross-platform.** A macOS app gets data, downloads, queries and elevation from maqs but renders maps some other way (MapKit for display, or a Catalyst build of the iOS app). Smallest change, no unmaintained dependency.
2. **Mac Catalyst.** The iOS xcframework has no Catalyst slice either; it would need verification that MapLibre builds for Catalyst at all. Untested; likely the same source-build burden as option 3.
3. **Build MapLibre for macOS from source** in `swift.yml` and vendor the resulting xcframework. Weeks of toolchain work against an unmaintained target; contradicts "reuse, don't build" and the one-dependency rule.

**Recommendation.** Option 1, with `Package.swift` declaring `MaqsUI` for iOS only and a note in the README. Revisit if MapLibre ships a macOS slice (7.x does not announce one).

**Consequences.** The brief's "Rendering" decision is amended: MapLibre renders on iOS and iPadOS; macOS rendering is out of this package's scope. The demo app is iOS-only. The design-system follow-ups recorded for Phase 4 (attribution slot, label font, hillshade) are unchanged; 3D terrain is off the table entirely since MapLibre Native does not implement it.

---

## 0004 — One map provider for online and offline: VersaTiles

**Date:** 2026-10-07 · **Status:** accepted (owner decision)

**Context.** The owner's rule after Phase 0: online and offline maps from one provider if at all possible, as few providers as possible, nothing unmaintained. Phase 0 had already shown the brief's mix (VersaTiles + OSMF for the basemap, AWS + a de-listed Protomaps sample for terrain) was partly stale. Checking VersaTiles' own catalogue: besides the Shortbread basemap it hosts an `elevation` tileset — Mapterhorn's terrarium build, 512 px WebP, z0–12 — on `tiles.versatiles.org/tiles/elevation` and as `elevation.versatiles` (407 GB, range-request extracts) on the download server. VersaTiles is actively maintained (v5.0.0 on 2026-10-04).

**Decision.**
- Basemap online: `https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}` (Shortbread 1.0, OSM + ESA WorldCover landcover). Offline: `versatiles convert --bbox … --compress gzip https://download.versatiles.org/osm-landcover.versatiles`. Landcover variant offline too, so the two match.
- Terrain online: `https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}`. Offline: `versatiles convert --bbox … https://download.versatiles.org/elevation.versatiles`.
- One CLI (`versatiles`) produces both tile layers; `pmtiles` stays only as an inspection tool.
- `config/sources.json` lists exactly one provider per layer. OSMF, AWS terrain tiles, the Protomaps sample and Mapterhorn-direct are dropped.
- Attribution set: OpenStreetMap contributors (ODbL), ESA WorldCover 2021 (CC BY 4.0), Mapterhorn and its per-source credits.

**Risk and mitigation.** tiles.versatiles.org is a demo server: no SLA, per-IP rate limiting, data refreshed roughly quarterly. Mitigations, neither built now: (1) `sources.json` can point at another provider without an app update; (2) our own release assets can be an online source for the covered regions — GitHub release downloads honour range requests (verified: `206`, `Accept-Ranges: bytes`) and MapLibre streams remote `pmtiles://` with an ambient cache since 6.27, so it is one config entry when wanted.

**Consequences.** Brief items 1 and 2 rewritten. The OSMF-specific policy work disappears, but the same etiquette (identifying User-Agent, no `no-cache`, honour `Cache-Control`) applies to VersaTiles and stays in the package rules. The manifest records the basemap's OSM timestamp separately from the Geofabrik-derived layers, since the basemap lags.

---

## 0005 — Road curvature: own implementation, not the `curvature` tool

**Date:** 2026-10-07 · **Status:** accepted (owner decision)

**Context.** `curvature` is feature-complete and still runs (ADR 0001), but it has had no commit since 2022, targets Python 3.5, needs `msgpack<1` pinned, and its GPLv3 licence lives in the README only. The owner's rule is to avoid dormant tools when the replacement is small.

**Decision.** Implement the scoring in `pipeline/` ourselves: per way, segments between consecutive nodes; per segment, radius by the three-point circle method; classify radii into the same bands `curvature` uses and sum the per-way score the same way, so the numbers remain comparable with the published ones. The `corners` table (apex, minimum radius, direction, entry/exit distance) is derived from the same per-segment radii, which the GPL tool would not have given us anyway. Highway-class and surface filters are configuration. Tested against hand-built fixtures (a straight road scores 0; a circular arc of known radius scores the expected band) and sanity-checked against `curvature`'s output for the test region (19 features, Phase 0).

**Rejected.** Pinning `curvature` at a commit with patches: works today, but it is a GPL tool nobody maintains, and we would be its maintainer in all but name.

**Consequences.** `curvature` leaves `bootstrap.sh`; the pipeline's only external CLIs are `versatiles`, `osmium`, `tippecanoe`. The Veneto run will be faster than the 169 s measured for the GPL chain if we use pyosmium directly, but that is not a goal.

---

## 0006 — Trails come from multiple sources through adapters

**Date:** 2026-10-07 · **Status:** accepted (owner decision); adapter sources beyond OSM each get their own ADR

**Context.** Italian trail stewardship is split: CAI sections across most of the country, the Alpenverein Südtirol in South Tyrol, SAT in Trentino, plus regional networks. OSM tagging follows the steward, so a CAI-only tag set misses South Tyrol almost entirely (25 % `cai_scale` coverage in Trentino-Alto Adige vs ~60 % in Veneto and Friuli). The owner wants trail data fetchable from more than one source, starting with AVS.

**Decision.**
- The trails layer is built from **adapters**. Each adapter turns one source into the same normalised record: id, `ref`, name, difficulty (a normalised scale plus the original value and its scheme — `cai_scale`, `sac_scale`, an AVS grade), operator, network, symbol, geometry, and provenance (`source`, `source_id`, `source_licence`, `source_date`). Downstream steps see only this format.
- `config/regions.yaml` declares the sources per region in priority order. Duplicate trails across sources are matched by `ref` and geometric overlap; the higher-priority source wins, the other is kept as a secondary reference row.
- The SQLite `trails` schema carries the provenance columns from version 1, and the manifest's attribution list is assembled from the sources actually used.
- **Adapter 1: OSM** (Phase 1). Our own pyosmium step reads `route=hiking` relations from the uncut Geofabrik file, assembles ordered geometry from member ways, flags gaps and reversals, and assigns relations to regions by intersection. Both `cai_scale` and `sac_scale` are kept.
- **Later adapters** are architected for, not built: the first release ships the OSM adapter only (owner, 2026-10-07). First candidate is the Alpenverein Südtirol (AVS itself or the Province of Bolzano open data); then SAT/Trentino, the Veneto and Friuli-Venezia Giulia regional networks, OSM2CAI. Each gets a source ADR (format, licence, attribution) before implementation; the candidate-source survey from Phase 0 is kept for that purpose.

**Rejected.** Hard-wiring OSM with CAI tags only (the brief's original wording): simplest, but demonstrably incomplete for one of the three launch regions.

**Consequences.** Brief item 4 rewritten. The pipeline grows a `trails/sources/` package with one module per adapter and a merge step; the first release ships with the OSM adapter alone, and the merge step is exercised in tests with a synthetic second source so the seam is proven before a real one arrives.

### Candidate trail sources (surveyed 2026-10-07, not implemented)

Verified live on 2026-10-07 for the future adapters. Each still needs its own short ADR before implementation.

| Source | What | Access | Licence | Carries | Notes |
|---|---|---|---|---|---|
| **Province of Bolzano, hiking routes** (the AVS-surveyed network; AVS handed its data to the Province and publishes nothing open itself) | `p_bz-TransportNetwork:Routes-HikingTrails`, 4,609 routes, updated daily | WFS 2.0 at `https://geoservices1.civis.bz.it/geoserver/p_bz-TransportNetwork/ows` (GeoJSON, SHAPE-ZIP, GML, CSV; EPSG:25832) | **CC0** per `https://data.civis.bz.it/dataset/percorsi-escursionistici` | ID, CODE (trail number, e.g. `2B`), NAME, MODIFY_DATE, LENGTH_GEOM — **no difficulty** | Maintainer per segment from the sibling CC0 layer `Routes-HikingTrailsSustainers` (14,786 segments: AVS 5,636 km, tourism boards 5,975 km, nature parks 3,367 km, CAI 591 km, SAT 121 km) via a spatial join. The Open Data Hub mirror of the same routes is flagged "closed", so use the WFS. The Euregio DIGIWAY dataset returns 403 and has no published licence: ignore |
| **SAT, Trentino** | 1,082 trails, monthly | `https://sentieri.sat.tn.it/download/sentierisat.shp.zip` (also GPX, KML) | **ODbL + DbCL**, attribution `© Società degli Alpinisti Tridentini (SAT)`; share-alike applies to the derived database | number (`E101`), difficulty T/E/EE/EEA-F/PD/D/MD, times, elevations | Best-attributed source of the lot; `dati.trentino.it` has no trail dataset |
| **Regione del Veneto, Sentieri Alpini** | `rv:c1013172_sentalpini`, 889 features | WFS on `idt2-geoserver` (SHAPE-ZIP) | IODL 2.0 (attribution) | number, difficulty E/EE, times, elevations | Update "notPlanned", last 2019: stale, use only to fill gaps |
| **Regione FVG, Sentieri CAI** | `SENTIERI_CAI_CTRN_ED1`, 440 features, self-declared incomplete | `serviziogc.regione.fvg.it` RETI_TRASP WFS / IRDAT shapefile | IODL 2.0 | `CODICE_SENTIERO` (`CAI 453`), no difficulty | No true regional network dataset found |
| **OSM2CAI** | CAI's validated routes, OSM-derived | Open JSON API: `https://osm2cai.cai.it/api/v2/hiking-routes/list`, `/api/v2/hiking-route/{id}` (GeoJSON with `ref`, `cai_scale`, `osm_id`, `validation_date`), bulk `/api/v2/export/hiking-routes/list`, GPX/shapefile endpoints | ODbL (OSM-derived); credit OSM contributors and "INFOMONT (© Club Alpino Italiano)" | ref, cai_scale, validation status | Useful as a *validation* overlay on the OSM adapter rather than a geometry source |

OSM tagging in South Tyrol (live Overpass, IT-BZ): 4,239 `route=hiking` relations; `ref` on 3,569; `osmc:symbol` on 3,573; `operator` on 1,104, of which 703 name AVS in four spellings; `cai_scale` on only 296; `sac_scale` on 7 relations but on 11,479 path *ways*. Consequence for the OSM adapter: normalise `operator` spellings, read `sac_scale` from member ways when the relation has none, and treat the Bolzano WFS as the authoritative geometry for that province once its adapter exists.

---

## 0007 — A bundled low-zoom base pack

**Date:** 2026-10-07 · **Status:** proposed (owner asked whether it is possible; numbers below); output named `base-<pack>-basemap.pmtiles` by 0009

**Context.** Apps should show *something* offline before any region pack is downloaded. Measured from the same VersaTiles file the real packs use, gzip, over the bbox of all three regions:

| Content | Size | Extract time |
|---|---|---|
| Basemap z0–9 | 5.7 MB | 5 s |
| Basemap z0–10 | 13.2 MB | 9 s |
| Basemap z0–11 | 32.5 MB | 9 s |
| Terrain z0–8 / z0–9 | 3.0 MB / 7.7 MB | 5 s |
| World basemap z0–5 (context outside the bbox) | 15.7 MB | 3 s |

**Decision (proposed).** The pipeline builds one extra asset per data release, `base-nordest-basemap.pmtiles`: basemap only, z0–10, all regions in one bbox, about 13 MB. No terrain (too coarse at those zooms to be useful for profiles) and no world layer (the landcover polygons make low zooms expensive). Apps include the file in their own bundle and register its URL with `MaqsCore`; the map view uses it as the lowest-priority tile source, below downloaded packs and online tiles. The file is **not** committed to this repo (no data in git) and is not a package resource (SwiftPM cannot fetch files at build time); a yearly refresh in the apps is enough, since the low-zoom basemap changes slowly.

**Consequences.** One more pipeline output and manifest entry (`base` pseudo-region, basemap layer only); one `MaqsCore` API to register a bundled pack; the style assembly in `MaqsUI` gains a third source tier.

---

## 0008 — Requirements from the consuming apps' corner alert, elevation, and privacy needs

**Date:** 2026-10-08 · **Status:** accepted (owner decision); the empty-`sources.json` opt-out of decision 3 is open in 0012

**Context.** A survey of the consuming apps' plans (kept outside this repo) shows what they need from maqs: not rendering or routing, but **offline data** for a free-drive tight-corner alert (map-match position and heading to the road, look ahead over precomputed corners, sensitivity bands, cards like "tight left · R 64 m · 400 m"), offline elevation for ride profiles and spot elevations, and mountain passes for crossing events. One app has a strict "no coordinates leave the device" privacy stance; another already defines corners and a twist score on recorded GPS tracks. The owner decided that maqs's requirements supersede the apps' existing internal rules where they conflict.

**Decisions.**
1. **Curvature schema carries what a lookahead needs.** Segments store their end-node ids (adjacency at junctions, so a lookahead can continue along the same `ref`/`name` across OSM way splits), `oneway`, `maxspeed` when tagged, `highway`, `surface`, `ref`, `name`. Corners are stored in way order with direction and entry/exit distances; the query API flips them for reverse travel. R\*Tree indexes both tables.
2. **One corner definition, shared.** The pipeline's road corners and the package's track analysis use the same documented formula: curvature from the three-point circle over consecutive points, corners as runs where |curvature| exceeds a threshold, radius from the circumcircle of entry, apex, and exit, a saturation radius, and the same aggregates (corner count, tightest radius, turning share). `docs/data-format.md` is the normative text; the package exposes the math as a pure, dependency-free function over coordinate arrays so an app's recorded-track metrics and the road corners agree by construction. This replaces the "curvature-compatible bands" wording in ADR 0005: compatibility with the GPL tool's numbers is no longer a goal.
3. **Online sources are optional per app.** An app may run with no online provider at all (empty `sources.json` or an explicit opt-out), using bundled and downloaded packs only, so a "data not collected" app never sends tile or DEM coordinates off-device. Every online request the package makes is attributable to a layer the app enabled.
4. **Bundled packs have a size target.** The curvature SQLite for all three launch regions should stay **under 30 MB**, and the base pack (ADR 0007) under 15 MB, so an app can ship both inside the app bundle without a download step. Phase 1 measures and reports; if the target is missed, geometry simplification or a per-region split is decided then, not by relaxing the target silently.
5. **Terrain API shape.** Besides single-point sampling and profiles, `MaqsTerrain` offers a batch sampler for a coordinate array (a whole route) and a grid sampler for a bbox (contour cards). z12 terrain (~27 m per pixel at 46° N) is the stated resolution; apps that need better wait for a higher-zoom layer.

**Consequences.** `docs/data-format.md` gains the adjacency and direction rules and the corner formula; `MaqsData`'s curvature query becomes "corners ahead along the road from a matched segment and direction", which needs adjacency; the places layer keeps `mountain_pass`/`natural=saddle` with `ele` as a first-class query for crossing detection. Routing stays out of scope: apps use the platform's directions and may rescore alternatives with the shared curvature function.

---

## 0009 — Regions as the smallest pack unit, the `triveneto` region, and the test-region fixtures

**Date:** 2026-10-15 · **Status:** accepted

**Context.** The owner needs Veneto, Trentino-Alto Adige and Friuli-Venezia Giulia together and will not use anything smaller than a region (owner rule, 2026-10-08). Tile extracts are cut by bbox, and the three regional bboxes overlap heavily (Veneto's already contains most of the other two), so three separate packs would cost an estimated 1 GB where the one combined pack measured about 720 MB (only Veneto and Triveneto were measured). The Swift tests need realistic fixtures, but nothing generated may be committed, and the `test` region's basemap plus terrain should stay under about 5 MB.

**Decisions.**
1. A region is the smallest unit a pack is cut at; there are no sub-region packs. `test` is `fixture: true`: built for CI and tests, never listed to apps, never released, never in a base pack.
2. `triveneto` is a first-class region with the union bbox (10.3818,44.7923,13.9187,47.0921). Measured on 2026-10-08: basemap 431 MB (z0–14, gzip, border 1, 48 s), terrain 291 MB (z0–12, 21 s). These figures predate the final pipeline code. That code was measured on Veneto (below), which takes the same code path, so the triveneto pack was not rebuilt; the first real build will re-measure it. The single regions stay for users who want less.
3. Each region sets its own tile border with `bbox_border` in `regions.yaml` (default 1); the basemap and terrain steps pass `--bbox-border` only when it is above 0. Base packs never have a border. The one-tile ring costs at least about 15 MB at z0–11, however small the bbox: with a border the `test` bbox came to 18,919,607 bytes, and even a 200 m bbox to 17.4 MB. So `test` sets `bbox_border: 0`; real regions keep 1.
4. The `test` bbox is 12.21,46.08,12.29,46.13, about 34 km² around Nevegal. Measured on 2026-10-15 without a border: basemap 1,617,480 bytes (40 tiles), terrain 1,496,730 bytes (14 tiles), 3,114,210 bytes together, under the 5 MB warning line. The local build takes 18.8 s.
5. Fixtures are not committed. The `pipeline` workflow builds the test region on every push or pull request that touches the pipeline or its configuration and uploads `dist/test` as the `test-region-fixtures` artifact; the Swift workflow (Phase 4) will download it. Only tiny hand-made corrupt-input files live in git; the pipeline's own tests generate their archives in code.
6. Regions can be anywhere in the world: each names its Geofabrik extract and an optional admin-relation clip. Base packs are named lists of regions, not "everything".

**Other measurements (2026-10-15, versatiles 5.0.0, macOS).** ADR 0001's Phase 0 figures for Veneto (238 MB basemap, 105 MB terrain) were low. With border 1, Veneto measures basemap 273,130,150 bytes (20,296 tiles, 31.8 s) and terrain 163,675,404 bytes (1,664 tiles, 15.4 s). The border adds about 1,060 basemap and 330 terrain tiles, and VersaTiles' elevation tiles weigh about a quarter more per tile than the Mapterhorn extract Phase 0 measured: 133 MB against 105 MB for the same 1,331 tiles. The base pack `triveneto` (z0–10, no border) measures 13,165,829 bytes (186 tiles, 7.6 s), under ADR 0008's 15 MB target.

**CONTRADICTS BRIEF (minor):** the brief's `test` region is "a few km²". The 34 km² bbox is expected to hold more than the three trails the Phase 0 probe bbox held; the count will be known once the trails layer is built.

**Consequences.** `config/regions.yaml` carries five entries; adding a region elsewhere is one more. ADR 0007's single `base-nordest` file becomes one `base-<pack>-basemap.pmtiles` per configured base pack, today `base-triveneto-basemap.pmtiles`. The release workflow (Phase 3) will skip fixture regions. The fixtures do not exercise the border; the step unit tests check the `--bbox-border` argument instead. ADR 0008's "~27 m per pixel" at z12 assumed 256 px tiles; the measured terrain archives are 512 px, so z12 is about 13 m per pixel at 46° N.

**Verification of `terrain-hd` (2026-10-15, macOS, Homebrew `pmtiles` 1.31.2, which reports `dev`).** One live run on a scratch region with bbox 11.24,46.0,11.26,46.02, which straddles the zoom-6 boundary at 11.25° E, at `hd_max_zoom` 13. The step picked archives `6-33-22` and `6-34-22`. Each `--dry-run` printed `fetching 2 tiles, …`, the line the step parses. `pmtiles extract` accepted the argv as built (`--bbox=… --minzoom=13 --maxzoom=13`), and `pmtiles merge` joined the two parts. The output validated: WebP, tile compression none, zoom 13–13, 4 tiles, 412,663 bytes, clustered, attribution "© Mapterhorn". The step took 7.2 s, the whole command 8 s, and needed no code change. Two edge cases were probed by hand. A published archive with no tiles in the bbox prints `fetching 0 tiles` and exits 0, so the step skips it. An archive Mapterhorn does not publish answers HTTP 404: `pmtiles extract` exits 1 and the step fails instead of skipping it. The four archives under the launch regions (`6-33-22`, `6-33-23`, `6-34-22`, `6-34-23`) all answer 200, so that only matters for a region elsewhere. The Linux release binary was not run against Mapterhorn.

---

## 0010 — Geometry encoding and the Python libraries for the data layers

**Date:** 2026-10-15 · **Status:** accepted

**Context.** The brief asks for one compact geometry encoding for every layer, encoded polyline or float32 blobs, chosen by ADR. Size matters most for curvature: ADR 0008 wants the curvature file for the three launch regions under 30 MB so apps can bundle it. The Swift package decodes every geometry it reads on the device, with system frameworks only. The data layers also need two things the CLIs do not do: assembling hiking relations from their member ways (`osmium export` skips route relations, ADR 0001) and reading terrain tiles for ascent and descent.

**Decision.**
- Every line is a Google encoded polyline at precision 6, stored as TEXT; a trail's legs are joined by `;`. Points are plain `lon`/`lat` REAL columns. `docs/data-format.md` specifies the format.
- Two Python libraries become runtime dependencies of the pipeline, pinned in `uv.lock`. pyosmium (`osmium` 4.3.1, BSD-2-Clause) reads the OSM cuts with node locations for all three layers. Pillow (12.3.0, MIT-CMU) decodes the WebP terrain tiles. Both publish Python 3.12 wheels for macOS (arm64, x86_64) and manylinux (x86_64, aarch64), so CI installs them without a compiler, and both are maintained (the pinned releases are from 2026-04-02 and 2026-07-01). pyosmium brings `requests` and its four dependencies (`certifi`, `charset-normalizer`, `idna`, `urllib3`); Pillow brings none. Neither reaches the Swift package.
- The pipeline reads PMTiles tiles itself (`pmtiles_reader.py`, next to the header reader) and uses no GIS library: osmium does the spatial cut.

**Rejected.**
- float32 blobs: every vertex costs 8 bytes. A polyline6 vertex costs one character per five bits of each zigzagged delta, so at 46° N a vertex less than 1.2 km from the previous one takes at most 6 characters; only the first vertex of a line takes more (11 for the example in `data-format.md`). The text also stays readable in the `sqlite3` shell.
- `|` between trail legs: it is a polyline character (the example point encodes as `_av|vA_xtjV`), so it cannot separate polylines. `;` is outside the alphabet.
- `pmtiles tile` as a subprocess for every terrain tile: one process per tile, where a small bounds-checked reader runs in-process and is unit-tested.
- shapely: nothing needs it. osmium cuts by polygon, and the geometry the layers use (distances, circles, resampling) is a few functions in `geometry.py`.

**Consequences.** `MaqsData` decodes polyline6 and splits trail geometry on `;`; the worked example in `data-format.md` is ready-made test data. The Swift products link nothing new. The pipeline goes from two direct runtime dependencies (`click`, `pyyaml`) to four. ADR 0008's curvature size result is in ADR 0011.

---

## 0011 — Data-layer formulas, thresholds and the first measurements

**Date:** 2026-10-15 · **Status:** accepted (formulas and thresholds); open for the owner: the curvature size against ADR 0008 and the ascent rule for partly covered trails

**Context.** The data layers need numbers the brief leaves open: how finely to sample a trail for ascent, how much terrain noise to ignore, how to rank places, when two road vertices count as one, what a corner is. ADR 0008 sets a 30 MB target for the bundled curvature file. The first builds of the real regions were also the first check of the cuts and counts against Phase 0.

**Decision.** `docs/data-format.md` has the normative text of every formula; this records the constants and the reasons.

- Hiking cut: trails read a per-region `osmium extract -s smart -S types=route` of the `route=hiking` filter of the whole Geofabrik extract. It keeps every relation with a member in the region, with all its members. That is how the brief's "relations from the uncut file" works per region: a relation that crosses the region's border stays whole. Relations missing member ways that lie outside the Geofabrik extract itself still show as `incomplete`. In Veneto 44 of 1,953 trails (2.3 %) are `incomplete`; ADR 0001's 5.1 % counted missing members of every type.
- Ascent and descent: a trail is sampled every 25 m, about two pixels of z12 terrain at 46° N, with a 5 m hysteresis so that small elevation differences between neighbouring samples do not add up. Only samples over the region's terrain archive count. Open for the owner: a trail partly outside the archive keeps the value over the covered part, with a `terrain_gap` anomaly, and is null only when nothing is covered. The row itself does not say the value is partial; the build report does. Keeping the partial value gives an ascent to the relations that leave the region (the brief puts those at 5–10 %); the alternative is null whenever any sample lacks a tile.
- Places: `rank_score` = 1000 × [wikidata present] + ele. A `wikidata` tag weighs as much as 1,000 m of height: a notable village or hut ranks with the high peaks, and among peaks the height decides. In Phase 0, 41 % of Veneto's place nodes had `wikidata` and 32 % had `ele`, so both inputs carry signal. The brief asks for a simple formula, and this one has two inputs.
- Curvature: vertices closer than 5 m are merged, from both ends of the way. Without the end pass, a way whose last node sits 2 m past the previous one and 1 m off the line, as junction nodes often do, scores a 58 m corner. The bands are those of `curvature`: weight 4, 3, 2, 1 under 30, 60, 100, 175 m. A corner is a run of same-direction vertices under 500 m, and its radius is the circle through entry, apex and exit (ADR 0008).
- Score attribution: each vertex's band weight covers half of each adjacent segment, instead of the segment after it as in `curvature`. The per-segment rule made the score depend on the direction the way was drawn in: a hook-shaped test road scored 236.5 one way and 54.1 the other. On a two-way road the drawing direction means nothing.
- Two-node and straight ways are kept with score 0 and no corners. They carry the node adjacency a lookahead follows across straight connectors (ADR 0008). Rejected: skipping ways with fewer than three nodes, which breaks that chain. `oneway` comes from the explicit tag only.
- Difficulty: one 1–6 scale built on SAC's six grades, with CAI's grades placed against it (the table is in `data-format.md`). The relation's `cai_scale` wins, then its `sac_scale`, then the hardest `sac_scale` of its member ways, because South Tyrol grades ways, not relations (ADR 0006).
- Trail merge: a lower-priority record becomes a secondary when its `ref` matches and more than half of it, resampled every 25 m, lies within 50 m of the winner (plus half the sample step, since points are compared with points). Records from one source are never merged with each other. Only OSM exists today, so every row is a primary.
- The `expect` ranges in `config/regions.yaml` are the measured counts below times 0.6 to 2, rounded. Veneto keeps the trails and places ranges derived from Phase 0. The `test` region has no `expect` block; the network test asserts about 60–200 % of its counts instead.

**Measurements (2026-10-15, macOS, the nord-est extract downloaded that day, 625,529,465 bytes).**

The `test` region with all five layers took 64.5 s, which probably includes the extract download; a rerun with nothing to do took 0.8 s.

| Step | Seconds | Outputs (bytes) | Rows |
|---|---|---|---|
| basemap | 10.9 | 1,617,480 (40 tiles) | |
| terrain | 10.2 | 1,496,730 (14 tiles) | |
| trails | 32.9 | SQLite 126,976; overlay 191,218 (442 tiles) | 10 trails |
| places | 4.0 | SQLite 40,960; overlay 4,388 (23 tiles) | 22 places |
| curvature | 5.7 | SQLite 176,128 | 136 segments, 623 corners |

Of the 10 test trails, 7 are `ordered`, 2 `incomplete` and 1 `gaps`; 6 are graded by `cai_scale`, 3 by `sac_scale:ways`, 1 not at all. All 10 have an ascent. The longest, the 353.6 km Traumpfad München–Venedig, reports 303 m: only its samples over the test region's terrain count.

The real regions were built with trails, places and curvature only. Without terrain in those runs, `ascent_m` is null throughout, with one `terrain_missing` anomaly per build.

| Region | Trails (`expect`) | Places (`expect`) | Segments (`expect`) | Corners | Seconds: trails / places / curvature |
|---|---|---|---|---|---|
| veneto | 1,953 (1,500–3,000) | 13,400 (10,000–18,000) | 128,590 (75,000–250,000) | 227,742 | 19.9 / 14.5 / 18.8 |
| triveneto | 8,686 (5,000–17,000) | 29,198 (17,000–58,000) | 221,044 (130,000–440,000) | 460,364 | 39.0 / 37.9 / 39.9 |
| friuli-venezia-giulia | 1,267 (750–2,500) | 5,830 (3,500–11,500) | 47,015 (28,000–94,000) | 88,929 | 10.4 / 6.4 / 6.0 |
| trentino-alto-adige | 5,786 (3,500–11,500) | 10,150 (6,000–20,000) | 45,600 (27,000–91,000) | 144,520 | 20.2 / 6.7 / 7.3 |

| Region | trails.sqlite | trails.pmtiles | places.sqlite | places.pmtiles | curvature.sqlite |
|---|---|---|---|---|---|
| veneto | 5,099,520 | 6,712,772 | 1,998,848 | 1,452,413 | 58,818,560 |
| triveneto | 18,939,904 | 22,451,583 | 4,648,960 | 3,399,942 | 111,792,128 |
| friuli-venezia-giulia | 4,329,472 | 4,246,707 | 1,007,616 | 704,302 | 22,237,184 |
| trentino-alto-adige | 11,309,056 | 13,993,920 | 1,699,840 | 1,285,656 | 30,420,992 |

The places overlays above were built before the places step passed `-r1`, so tippecanoe had thinned their points below z14. With `-r1` Triveneto's places overlay keeps all 29,198 places at every zoom and is 7,515,620 bytes (15,410 tiles), 2.2 times the size above.

| Region | `geometry_status`: ordered / gaps / incomplete | `difficulty_scheme`: none / cai_scale / sac_scale / sac_scale:ways |
|---|---|---|
| veneto | 1,596 / 313 / 44 | 282 / 1,199 / 2 / 470 |
| triveneto | 7,156 / 1,331 / 199 | 2,128 / 3,240 / 11 / 3,307 |
| friuli-venezia-giulia | 1,103 / 82 / 82 | 186 / 761 / 0 / 320 |
| trentino-alto-adige | 4,701 / 971 / 114 | 1,702 / 1,477 / 9 / 2,598 |

Veneto matches Phase 0: 1,953 trails against 1,955 relations, 13,400 places against 13,408 nodes. Triveneto's 8,686 trails are fewer than the three regions' 9,006 because a relation that spans regions counts once. In Trentino-Alto Adige 2,598 of 5,786 trails (45 %) are graded from their ways' `sac_scale`, as ADR 0006 expected.

The trails steps recorded 20,050 anomalies for Veneto, 72,857 for Triveneto, 16,687 for Friuli-Venezia Giulia, 43,392 for Trentino-Alto Adige and 1,427 for `test`, listing every reversed member way on its own. The build now writes one `reversed` entry per relation and counts every kind (`anomaly_kinds`). Veneto and Triveneto were rebuilt that way the same day (trails only, same extract, no terrain):

| Region | Total | `missing_member` | `reversed` (relations) | `gap` | `role` | `relation_member` | `no_geometry` | `difficulty` | `terrain_missing` |
|---|---|---|---|---|---|---|---|---|---|
| veneto | 3,319 | 840 | 1,421 | 639 | 341 | 39 | 38 | 0 | 1 |
| triveneto | 19,657 | 9,411 | 6,368 | 2,228 | 1,474 | 90 | 84 | 1 | 1 |

Friuli-Venezia Giulia, Trentino-Alto Adige and `test` have not been rebuilt, so their per-kind counts are not measured. The rebuild also orients every leg by member order (`data-format.md`), and the first point moved for 563 of Veneto's 1,915 trails with geometry and 2,371 of Triveneto's 8,602: in Veneto 507 first legs now run the other way, 45 loops are walked the other way round and 11 loops only start elsewhere, so the first build had more than a quarter of the trails backwards, with ascent and descent swapped. Without the old first-way flip, a way that closes a loop can be chained at the other end of the leg, which adds one leg to 3 Veneto and 5 Triveneto trails; one Veneto trail moves from `ordered` to `gaps` (the status table above is from the first build). The places steps recorded one `ele` anomaly each in Triveneto and Trentino-Alto Adige.

The `test` build meets its 5-minute budget with a wide margin, in CI too; the CI timings are in `docs/architecture.md`.

**Curvature size against ADR 0008.** `triveneto-curvature.sqlite` is 111,792,128 bytes (111.8 MB). Veneto, Friuli-Venezia Giulia and Trentino-Alto Adige together are 58,818,560 + 22,237,184 + 30,420,992 = 111,476,736 bytes (111.5 MB). The 30 MB target is missed by 3.7×. A per-region split does not help: the three files add up to the combined one within 0.3 %, and only Trentino-Alto Adige alone comes close (30.4 MB). As ADR 0008 asks, the target is not relaxed silently. The build report records every file's size; nothing enforces the target. The options, none of them chosen:

- fewer highway classes (`curvature.highways` is configuration), for example without `unclassified` or the `_link` classes;
- dropping zero-score segments, which also drops the adjacency a lookahead follows across straight connectors;
- dropping the `corners_rtree` table; corners stay reachable through their segment and the `corners_segment` index;
- moving the corners into a separate file;
- simplifying the stored geometry after scoring, so corner distances no longer match the stored line exactly;
- revising the target.

How the bytes split between tables and indexes has not been measured. The decision is the owner's. Nothing in the release path depends on it: the target is about bundling the file inside an app.

**CONTRADICTS BRIEF (minor):** brief item 6 asks for the per-way score summed "the way `curvature` does", so the numbers stay comparable. ADR 0008 already dropped comparability as a goal. The bands are the same, but the half-segment attribution gives different scores from `curvature`'s; item 6 should be amended.

**Consequences.** The Swift package mirrors these formulas from `data-format.md` (ADR 0008). A release build must include terrain whenever it builds trails; the fixed step order runs terrain first. Open: the owner's decisions on the curvature size and on the ascent rule for partly covered trails, and the per-kind anomaly counts of Friuli-Venezia Giulia and Trentino-Alto Adige.

---

## 0012 — Manifest, sources and the compatibility rule

**Date:** 2026-10-16 · **Status:** accepted (owner decision 2026-10-16); open: the online opt-out of ADR 0008 (the schema requires one source per layer, so an app-side setting would replace the empty-file opt-out)

**Context.** Phase 2 of the brief defines the two files every client reads: `manifest.json`, one per data release, and `config/sources.json` on `main`. Shipped apps parse both, and an app on someone's phone keeps reading new releases for months without an update, so the two formats are a public API. Each layer's schema will change on its own schedule, and some changes will come before the Swift package (Phase 4) exists. The manifest also has to list the base pack (ADR 0007) and give each layer's OSM date separately, because the VersaTiles basemap lags Geofabrik by months (ADR 0004).

**Decision.** `docs/data-format.md` has both formats and the full compatibility rule. In short:

- Old and new schema versions sit side by side for one release. When a layer's schema changes incompatibly, the next release ships the new files and the previous version's files. The manifest lists every version of a layer, highest first; a client takes the newest it can read, and a layer it cannot read is unavailable while the others keep working.
- File names carry the version from the first release on: `<label>-<layer>.v<N>.<ext>`, so two versions of a layer fit in one release. The tile layers get `layer_schema_version` 1, defined in `data-format.md`; the SQLite layers already had it. File names in ADRs 0007, 0009 and 0011 predate the suffix.
- Every `url` in the manifest is pinned to a release tag. Only `manifest.json` itself is read through `releases/latest/download/`.
- The producer is strict and clients are tolerant. The JSON Schemas in `config/schemas/` (draft 2020-12) allow no unknown field on any object except region `name`, which allows further language keys; clients ignore fields they do not know.
- `jsonschema` validates both files. It is the pipeline's only new dependency (`jsonschema>=4.23` in `pyproject.toml`) and reaches nothing in the Swift package. From `uv.lock`: jsonschema 4.26.0 (MIT), with attrs 26.1.0 (MIT), jsonschema-specifications 2025.9.1 (MIT), referencing 0.37.0 (MIT), rpds-py 2026.9.1 (MIT) and, on Python older than 3.13, typing-extensions 4.16.0 (PSF-2.0).
- JSON Schema's `pattern` is an ECMA-262 regex, but `jsonschema` runs it with Python's `re`, and the two differ in ways the schemas hit. The schemas and `maqs/schemas.py` work around those differences, so the files are judged as the JSON Schema spec says; [`data-format.md`](data-format.md#validation-rules) has the mechanics. A new pattern that needs other ECMA behaviour has to be checked against both engines.
- `maqs manifest` assembles the manifest from the build reports, not the workflow, so the file is validated where it is written and the assembly is unit-tested. `--previous` carries the older versions over.
- The `release` and `url` patterns also accept `data-ci`, so that CI can assemble and validate a real manifest from the `test` build without a release to publish it to. A `data-ci` manifest is never published; how it is built is in [`data-format.md`](data-format.md#manifestjson-manifest_version-1).
- `maqs check-config` is the gate for `regions.yaml`, `sources.json` and, with `--manifest`, a manifest. The smoke job runs it, and the unit tests validate the real `sources.json`.
- `config/sources.json` has one source per layer, both VersaTiles (ADR 0004).

**Verified live on 2026-10-16.**

| Fact | Verified value | Source |
|---|---|---|
| Basemap TileJSON | `https://tiles.versatiles.org/tiles/osm/tiles.json`: TileJSON 3.0.0, zoom 0–14, `tile_schema` `shortbread@1.0`, `tile_format` `application/vnd.mapbox-vector-tile`, tiles at `/tiles/osm/{z}/{x}/{y}`; attribution names © OpenStreetMap contributors and CC BY 4.0 ESA WorldCover 2021; `planetiler:osm:osmosisreplicationtime` 2026-06-07T23:59:58Z | the TileJSON |
| Terrain TileJSON | `https://tiles.versatiles.org/tiles/elevation/tiles.json`: TileJSON 3.0.0, zoom 0–12, `tile_schema` `dem/terrarium`, `tile_format` `image/webp`, tiles at `/tiles/elevation/{z}/{x}/{y}`; attribution © Mapterhorn. The TileJSON gives no tile size; tile 0/0/0 decodes as a 512 × 512 WebP | the TileJSON; one tile |
| Caching | On 2026-10-16 one request for tile `osm/0/0/0` returned `Cache-Control: public, max-age=21600, no-transform` and a weak `ETag`, and a repeat with `If-None-Match` got 304 with no body. The VersaTiles guide (ADR 0001) states there is none. The two TileJSON responses also carried a weak `ETag`, but no conditional request was sent for them; elevation tiles were not checked | response headers |

**Rejected.**
- Unavailable, never broken: no overlap window, so a client that finds only a newer version reports the layer unavailable. Simpler, but an old app silently loses a layer the day its schema changes.
- Additive forever: never change a schema incompatibly. That forbids fixing a schema mistake even now, before Phase 4 has written any client.
- Assembling the manifest in the workflow with `jq`: nothing validates the file where it is written, and nothing tests it.

**CONTRADICTS BRIEF (minor):** the brief's Phase 1 output table names the files without a version (`<region>-trails.sqlite`). Every output now carries `.v<N>.`, so the table should be amended.

**Consequences.**
- For one month after a bump, that layer's files are in the release twice, once per version. Each file stays under the 1.9 GiB asset limit as before.
- Phase 3 has to download the latest manifest before assembling a new one and pass it as `--previous`. `maqs manifest` carries an entry only when its URL names the previous manifest's own release, or every lower entry on a same-month re-run, so the window ends after one release and the workflow counts nothing. Carried entries keep the earlier tag's URL, so the workflow keeps those assets and never deletes an asset a published manifest names, also when a month is re-run. Re-uploading carried files under the new tag is not an option, because the URL tag is how the window ends.
- The previous manifest is validated against the schema before anything is carried, and a `data-YYYY-MM` release refuses one that is `data-ci` or from a later month.
- `shortbread_version` is the Shortbread version of the newest basemap entries. While a basemap bump is carried over, the older entries can follow another Shortbread version, so clients choose basemap files by `layer_schema_version` and map it to a Shortbread version through `data-format.md`.
- Phase 4 has to implement the client side of the rule exactly as `data-format.md` states it.
- ADR 0008 lets an app run without online sources through an empty `sources.json` or an explicit opt-out. An empty file fails the schema, since each layer needs at least one source. Whether an app-side setting replaces the empty-file opt-out is open for the owner (status line).
- A `dist/` built before the versioned names is rebuilt, not reused: `maqs manifest` refuses its reports.
- The curvature size question (ADR 0011) is unaffected.
