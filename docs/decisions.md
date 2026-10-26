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

**Date:** 2026-10-08 · **Status:** accepted (owner decision); the opt-out of decision 3 is the `onlineTiles` setting of 0014, not an empty `sources.json`; decision 5's "~27 m per pixel" at z12 is about 13.3 m with 512 px tiles (0009, 0015)

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

**Date:** 2026-10-15 · **Status:** accepted; decision 5 replaced by 0014 (the Swift fixtures are committed)

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

**Date:** 2026-10-16 · **Status:** accepted (owner decision 2026-10-16); the open question on the online opt-out of ADR 0008 is closed by 0014 (an app-side setting, `onlineTiles`)

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
- Phase 3 has to download the latest manifest before assembling a new one and pass it as `--previous`. `maqs manifest` carries an entry only when its URL names the previous manifest's own release, or every lower entry on a same-month re-run, so the window ends after one release and the workflow counts nothing. Carried entries keep the earlier tag's URL. The workflow never deletes or replaces an asset on an earlier release, so carried entries stay online. On the month's own release a re-run replaces same-named assets with `--clobber` (delete, then upload); after a successful run every file the new manifest names is present (ADR 0013). Re-uploading carried files under the new tag is not an option, because the URL tag is how the window ends.
- The previous manifest is validated against the schema before anything is carried, and a `data-YYYY-MM` release refuses one that is `data-ci` or from a later month.
- `shortbread_version` is the Shortbread version of the newest basemap entries. While a basemap bump is carried over, the older entries can follow another Shortbread version, so clients choose basemap files by `layer_schema_version` and map it to a Shortbread version through `data-format.md`.
- Phase 4 has to implement the client side of the rule exactly as `data-format.md` states it.
- ADR 0008 lets an app run without online sources through an empty `sources.json` or an explicit opt-out. An empty file fails the schema, since each layer needs at least one source. Whether an app-side setting replaces the empty-file opt-out is open for the owner (status line).
- A `dist/` built before the versioned names is rebuilt, not reused: `maqs manifest` refuses its reports.
- The curvature size question (ADR 0011) is unaffected.

---

## 0013 — Release workflow

**Date:** 2026-10-16 · **Status:** accepted (owner decision 2026-10-16)

**Context.** Phase 3 of the brief asks for `build-maps.yml`: a monthly cron and a manual dispatch with optional `region` and `layers` inputs, one job that downloads the Geofabrik extract and shares it, a matrix job per region, and a final job that assembles `manifest.json`, creates the `data-YYYY-MM` release with `gh`, uploads every asset and marks the release latest. Re-running a month must replace its assets. The release is the production endpoint: every installed app reads `releases/latest/download/manifest.json`, so a month that failed halfway must never become latest. ADR 0012 adds two requirements. The new manifest is assembled with the latest published one as `--previous`, and the files that carried entries name stay online.

**Decision.** `docs/architecture.md` describes the workflow step by step. In short:

- Three jobs on `ubuntu-24.04`: `prepare` (15 min), a `build` matrix with one leg per target (45 min each) and `release` (60 min). The cron is `0 3 1 * *`, 03:00 UTC on the 1st. A run is full when both inputs are empty and it runs on `main`. Every cron run is full, because scheduled runs use the default branch. The workflow has `contents: read`, and only `release` gets `contents: write`. Runs share one concurrency group with `cancel-in-progress: false`, so a publishing run always finishes.
- Only `main` publishes. On any other ref `prepare` sets `full=false` and logs `not on main: build only`. It does that after planning the targets, so a branch dispatch with empty inputs builds every leg of a full run and stops there. The `release` job's `if` also requires `github.ref == 'refs/heads/main'`, so the gate does not rest on `prepare` alone.
- `prepare` runs `maqs check-config` and plans the run from `maqs regions --json`: the targets, the tag `data-$(date -u +%Y-%m)` and the layers. A full run targets every non-fixture region plus `base`. The `layers` input must be comma-separated lowercase names (`^[a-z-]+(,[a-z-]+)*$`), because it is written to `GITHUB_OUTPUT`, where a newline would add an output. The job then restores `.cache/geofabrik` under `geofabrik-nord-est-<md5>`, the key `pipeline.yml` already uses, so both workflows share one cached extract. On a miss `maqs fetch --extract europe/italy/nord-est` downloads the file and checks its MD5, and the cache is saved when the job ends. On a hit the command does nothing.
- Each region's `build` leg restores the extract with `fail-on-cache-miss`, so no leg downloads it again; the `base` leg reads no OSM data and skips it. Every leg runs `maqs build --region <target> [--layers …]` and uploads `dist/<target>` as the artifact `dist-<target>`, kept 7 days. `fail-fast` is off.
- `release` runs only on a full run whose legs all passed. It runs `maqs manifest`, `maqs check-config --manifest` and `maqs release-check` before any upload. `release-check` requires every file the manifest names under this tag to be in `dist/` with the manifest's bytes and SHA-256. There is one exception, with `--previous`: a file the previous manifest names under this tag with the same SHA-256 passes without being in `dist/`, and it is not uploaded again. That is the case after a schema bump in a month that already has a release, because `maqs manifest` carries the old version from the month's first run, and that file is already on the release. Asset names must be unique in the release. `release-check` prints `<label>/<file> <bytes>` for each file to upload, and the upload step reads those paths. A full run has built every region and base pack the tag needs, so `--regions` is not passed.
- Publishing order: `gh release create <tag> --target "$GITHUB_SHA" --latest=false` when the release does not exist yet; `gh release upload --clobber` for the assets; `manifest.json` after them, also with `--clobber`; then `gh release edit <tag> --latest`. A new release stays off latest until its manifest is up.
- `maqs previous-manifest` picks the previous manifest from the release list (`gh api repos/<repo>/releases --paginate`, its pages joined with `jq -s 'add'`). The candidates are the published `data-YYYY-MM` releases, newest tag first, and the previous one is the newest candidate with a `manifest.json` asset. A newer candidate without one was left by a run that failed before its last upload. If it is this run's own tag, this run repairs it, with a warning. If it is older than another such candidate, it is an orphan that clients never saw, and it gets a warning too. If it is the newest candidate and another month, the step fails: carrying over from an older manifest would end ADR 0012's window early without an error. Only the owner resolves that, by re-running the workflow while that month lasts or by deleting the release with `gh release delete <tag> --cleanup-tag`. The workflow never deletes a release. A `gh` error also fails the step. The release list does not say which release is latest, so a non-data release that is newest by `created_at` gets a warning.
- Carried URLs are never rewritten. The workflow never deletes or replaces an asset on an earlier release. On the month's own release `--clobber` deletes and re-uploads same-named files, and after a successful run every file the new manifest names is present.
- A dispatch with `region` or `layers` set is a subset run. It builds and uploads the artifacts for inspection and skips `release`.
- Disk space is checked, not freed: each `build` leg fails under 6 GB free on its own runner before it builds. The largest leg, `triveneto`, writes about 0.9 GB (ADRs 0009 and 0011) next to the 0.6 GB extract. A full run's artifacts come to an estimated 2 GB: the tile sizes in ADR 0009, the data layers in ADR 0011 and the 13 MB base pack. `release` downloads all of them and uploads them, which is why it has 60 minutes; its runner is not checked.
- Third-party actions are pinned to a full commit SHA with the version in a comment, in both workflows (`astral-sh/setup-uv@37802adc94f370d6bfd71619e3f0bf239e1f3b78 # v7.6.0`). GitHub's own `actions/*` stay at major tags. In `build-maps.yml`, `GH_TOKEN` is set only on the steps that call `gh`, every checkout has `persist-credentials: false`, and inputs and matrix values reach the shell through `env`. `persist-credentials: false` keeps the token out of the git config, but the `release` job's `contents: write` token still reaches `actions/checkout` (`token`) and `setup-uv` (`github-token`) as the default value of an input; for setup-uv the SHA pin is the mitigation. `pipeline/tests/test_workflows.py` checks the pins in both workflows, the token scope, the checkouts, that no `run:` body contains an expression, the main-branch gate, the release timeout, the `gh release create` flags and the order of the release steps. `pipeline.yml` also runs when `build-maps.yml` changes, so those checks run on every edit.

**Verified on 2026-10-16.**

| Fact | Verified value | Source |
|---|---|---|
| `gh release upload --clobber` | "Delete and re-upload existing assets of the same name". If the upload fails, the original is already gone | gh manual |
| `gh release edit --latest` | exists | gh manual |
| `gh release download` | without a tag it reads the latest release, and then `--pattern` is required | gh manual |
| `gh release create` | a missing tag is created "from the latest state of the default branch" unless `--target` is given | gh manual |
| Latest release | "the most recent non-prerelease, non-draft release, sorted by the created_at attribute", where `created_at` "is the date of the commit used for the release" | GitHub REST docs |
| Runner disk | `ubuntu-24.04` had 86 GB free in `prepare`; ADR 0001 recorded about 20 GB | run 38901194493 |
| `gh release create --latest` | "Mark this release as "Latest" (default [automatic based on date and version]). --latest=false to explicitly NOT set as latest" | gh manual |
| `gh release delete --cleanup-tag` | "Delete the specified tag in addition to its release" | gh manual |
| `gh api --paginate` | "Each page is a separate JSON array or object"; `--slurp` would wrap them, the workflow joins them with `jq -s 'add'` | gh 2.97.0 manual |
| `make_latest` | "Specifies whether this release should be set as the latest release for the repository"; it defaults to true for a newly published release. The list of releases has no field that says which one is latest | GitHub REST docs |
| Token inputs | `actions/checkout` input `token` and `setup-uv` input `github-token` both default to `${{ github.token }}` | `action.yml` of checkout (`main`) and of setup-uv at the pinned SHA |
| Scheduled runs | "Scheduled workflows run on the latest commit on the default branch." "In a public repository, scheduled workflows are automatically disabled when no repository activity has occurred in 60 days." "Notifications for scheduled workflows are sent to the user who last modified the cron syntax in the workflow file." | docs.github.com, events that trigger workflows |

**Rejected.**
- One sequential job: no isolation between regions and no parallelism.
- Publishing subset runs. `maqs manifest` refuses a `data-YYYY-MM` manifest that lacks a non-fixture region or a base pack, and a release missing regions must never become latest.
- A third-party "free disk space" action: one more pinned dependency, to reclaim space the runner already has.
- Ignoring errors when fetching the previous manifest (`gh release download … || true`). A network or permission error would look like a first release, `maqs manifest` would run without `--previous`, and ADR 0012's one-release window would end early with no error.
- Taking the previous manifest from the release `gh release list` marks latest, in shell. Nothing tested it, and a latest release without `manifest.json` made the run a first release, which ended the window the same way.
- Deleting a half-published release from the workflow. It would repair the state without the owner, but a workflow that can delete releases can also delete the wrong one on the production endpoint.

**CONTRADICTS BRIEF (minor):** Phase 3 lists `swift.yml`, but there is no `Package.swift` to build yet, so it moves to Phase 4. Phase 3 also asks to free disk space up front; the workflow checks it instead, as above.

**CONTRADICTS BRIEF (minor):** the brief says "Adding a region anywhere in the world means adding one entry, nothing else". That holds for a region cut from the `europe/italy/nord-est` extract. A region from another Geofabrik extract also needs `build-maps.yml` edited: the MD5 URL, the cache key, the `maqs fetch` call and the extract check in `prepare` all name `europe/italy/nord-est`, and `prepare` fails while `regions.yaml` lists any other extract.

**Consequences.**
- A same-month re-run reuses the tag and skips `gh release create`. It deletes and re-uploads same-named assets, `manifest.json` last, and marks the release latest. When that release already was latest, the previous manifest is the month's own, so ADR 0012's same-month rule applies. After a schema bump the old version's files from the month's first run stay on the release: `release-check --previous` accepts them and they are not uploaded again. Older releases are not touched.
- A failed build leg skips `release`, and a failed `maqs manifest`, `check-config` or `release-check` stops it before any upload. The month's release, if there is one, stays as it was.
- On the first run of a month the new release is not latest until the last step. If an upload fails, the previous month stays latest, and its manifest names its own files and the carried entries of older releases.
- Accepted failure mode, on a same-month re-run: `--clobber` deletes each asset before it uploads the new one, so an upload that fails midway leaves the old `manifest.json` naming some files that are gone (a 404) and some that are already the new build (a SHA-256 mismatch). If the manifest upload itself fails, the old manifest is gone too, and the latest release has none. A re-run in the same month repairs the release: `maqs previous-manifest` warns and carries over from the newest earlier month that has a manifest. Once the month is over, the next month's run stops at that step until the owner removes the release.
- Phase 4 may assume that `manifest.json` is uploaded after every file it names. A missing asset, a SHA-256 mismatch and a missing manifest all mean the same to a client: keep the installed data, never install the file, and re-fetch the manifest later.
- The tag points at the commit the run built from. Two months tagged on the same commit tie on `created_at`, which is why the workflow sets latest explicitly.
- Package versions (`vX.Y.Z`, Phase 4) must be git tags only, or releases created with `--latest=false`. GitHub makes a newly published release latest by default, and a package release has no `manifest.json`, so every client would get a 404 from `releases/latest/download/manifest.json` until the next data release. `maqs previous-manifest` warns when a non-data release is newest by `created_at`.
- GitHub disables a scheduled workflow in a public repository after 60 days without repository activity, so a quiet stretch stops the monthly releases until someone runs `gh workflow enable build-maps.yml`. A failed scheduled run notifies the user who last changed the cron line.
- The schedule is live since the workflow reached `main` (commit 49fb052), so the first scheduled run is 2026-11-01 03:00 UTC. The first release is published by hand before that: a dispatch on `main` with both inputs empty, after a subset run has proven the build legs, and only on the owner's go. With no release yet there is no previous manifest, and that path (an empty release list, `maqs previous-manifest` prints `none`) runs live for the first time then. Afterwards `releases/latest/download/manifest.json` must return the file, and `maqs check-config --manifest` must accept it.

**Measurements.** A subset dispatch on 2026-10-16, `gh workflow run build-maps.yml -f region=test` (run 38901194493): `prepare` took 12 s, with targets `["test"]`, release `data-2026-10`, full `false`, 86 GB free and a Geofabrik cache hit on the key shared with `pipeline.yml`. `build (test)` took 74 s, `release` was skipped, and the artifact `dist-test` was 3,394,402 bytes. `pipeline.yml` stayed green on the same commit.

**First release.** `gh workflow run build-maps.yml` on `main` at 7fb4694 published `data-2026-10` on 2026-10-16 (run 38913426920, 6 min 53 s). `prepare` planned the targets triveneto, veneto, friuli-venezia-giulia, trentino-alto-adige and base, with `full` true and a Geofabrik cache hit. `maqs previous-manifest` found no published release with a `manifest.json`, so the run took the first-release path, and `release-check` accepted 29 assets (2,074,020,577 bytes) with none carried.

| Job | Duration |
|---|---|
| `prepare` | 19 s |
| `build (base)` | 43 s |
| `build (friuli-venezia-giulia)` | 3 min 04 s |
| `build (trentino-alto-adige)` | 2 min 48 s |
| `build (veneto)` | 3 min 23 s |
| `build (triveneto)` | 5 min 12 s |
| `release` | 78 s |

The legs ran in parallel. The REST API then returned release `data-2026-10` as not draft, not prerelease, target commit 7fb4694, marked latest, with 30 assets (the 29 files and `manifest.json`) and 2,074,036,371 bytes. `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json` answered 302, 302, 200, its `created_at` was 2026-10-16T14:15:17Z, and `maqs check-config --manifest` accepted it.

**Same-month re-run.** The same dispatch ran again (run 38914494150, 12 min 00 s). `prepare` took 19 s; the legs took base 41 s, veneto 4 min 06 s, triveneto 6 min 06 s, friuli-venezia-giulia 7 min 01 s and trentino-alto-adige 9 min 18 s, slower than the first run (runner variance); `release` took 2 min 17 s for the artifact download, the hashing and the 2 GB `--clobber` upload. `maqs previous-manifest` chose the month's own release, `data-2026-10`, and the log said "release data-2026-10 exists; assets will be replaced". `release-check` again saw 29 assets and none carried. Afterwards the release still had 30 assets and was still latest, and the manifest's `created_at` had moved to 2026-10-16T14:27:56Z. Both runs hit the Geofabrik cache, so the one download per run held.

---

## 0014 — `MaqsCore`: one entry point, manifest-driven discovery, verified installs

**Date:** 2026-10-16 · **Status:** accepted (owner decisions 2026-10-16)

**Context.** Phase 4 of the brief is the Swift package. It is built in four sub-projects, in this order: the package skeleton with `MaqsCore`, then `MaqsTerrain`, then `MaqsData`, then `MaqsUI` with the demo app. This ADR covers the first: `Package.swift`, `swift.yml`, the test fixtures and `MaqsCore`. Besides downloads and storage, the package discovers regions. It reads what the latest data release offers from `releases/latest/download/manifest.json`, never through the GitHub REST API, and tells the app. Two documents cross a trust boundary on the way in: the manifest decides which files land on the user's disk, and `sources.json` decides which hosts the app talks to.

**Decisions.**
1. Discovery is data and observable state only. `MaqsCore` publishes a `Catalog` of regions and base packs, each with its names, bbox, per-layer bytes and schema versions and an install status, and apps draw their own list. There is no region picker view, now or in `MaqsUI`.
2. Base packs work both ways. An app can register a base pack it bundles itself (ADR 0007) with `registerBundledBasePack(id:basemap:)`, and `MaqsCore` can download a base pack the manifest lists, on the same code path as a region. A registration lasts one launch and is not persisted, because the app bundle's path changes across app updates. A bundled pack is always `installed`, never `updateAvailable`. `install` of it downloads nothing, `remove` only unregisters it, and its `InstalledFile` has no SHA-256 and no data date.
3. The online opt-out of ADR 0008 is the configuration flag `onlineTiles`. When it is false, `onlineSources` is nil and `refreshOnlineSources` makes no request, so `MaqsUI` and `MaqsTerrain` never get a tile URL. Fetching the manifest and `sources.json` stays allowed, because those requests carry no position; an app that wants no network at all never calls a refresh. This closes the question ADR 0012 left open: an empty `sources.json` is not the opt-out, and the schema keeps requiring one source per layer.
4. The `test` region's outputs are committed under `Tests/MaqsTestSupport/Fixtures/`: its seven data files and the `data-ci` manifest, 3,584 KB today. `swift.yml` fails above 8,192 KB. This is the one place binary data may live in git, and it replaces decision 5 of ADR 0009, under which the Swift workflow would have downloaded the pipeline's artifact. `swift test` runs from a clean checkout with no Python, and `scripts/update-fixtures.sh` regenerates the fixtures and the bundled `sources.json`. Build reports are left out because they hold absolute local paths. So is the 13 MB base pack: the base-pack tests serve the test basemap under the base pack's name. Invalid manifests are derived in code from the fixture manifest, not committed as files.
5. One public `actor Maqs` sits over internal parts: the manifest and sources clients, the pack store, the download session and the installer. `MaqsTerrain` and `MaqsData` import nothing from `MaqsCore`; they take the file URLs of an installed pack. Whether `MaqsUI` depends on `MaqsCore`, and how `MaqsTerrain` and `MaqsUI` receive the online provider values (`TileSource` is a `MaqsCore` type today), is open and decided in their sub-projects.

**Package.** `swift-tools-version: 6.2`, Swift 6 language mode, iOS 18 and macOS 15. There is one library product, `MaqsCore`. `MaqsTestSupport` is a test-only library target at `Tests/MaqsTestSupport`, with its sources in `Sources/` and the fixtures as a copied resource, because SwiftPM resources must sit under the target's own path. `MaqsCoreTests` is the test target. Every target treats warnings as errors through `SwiftSetting.treatAllWarnings(as: .error)`. Nothing uses `unsafeFlags`, which would stop the package from being used as a dependency. `MaqsCore` imports Foundation, CryptoKit, Observation, Synchronization and os, nothing else.

**Refinements of the API.** `Maqs.init` is synchronous, runs on the main actor because it creates `MaqsState`, and throws `MaqsError.storage`, or `MaqsError.invalidConfiguration` when `userAgent` is empty or only whitespace. The configuration stays readable as the public `configuration` property. `RefreshPolicy` is a top-level type. `PackState` has a `queued` case for an install waiting its turn, next to `notInstalled`, `downloading`, `verifying`, `installed` and `failed`. `StorageError` adds `fileNotFound` and `invalidPackID`, and `DownloadError` adds `noCatalog` for an install before any catalog is loaded. `refreshOnlineSources` returns `OnlineSources?`, `nil` when online tiles are off; `diskUsage()` does not throw; `cancelInstall` is synchronous. `TileSource.tiles` is the URL template as a `String`, and `tilejson` is a `URL` that is never `nil`. Internally the installer cancels a download by its content key, `DownloadSession.cancel(key:)`, not by its URL. `pack.json` stores the `PackID` in the shape Swift synthesizes for the enum, `{"region":{"_0":"veneto"}}`, and the golden test pins it; an explicit coding is decided before `v0.1.0`.

**Trust boundaries.** The client asks more of the manifest than that it decodes ([`Manifest.swift`](../Sources/MaqsCore/Manifest/Manifest.swift)):
- `manifest_version` must be 1. Another number is `unsupportedVersion` and a body that is not JSON is `invalid`; either way the cached manifest stays.
- Every entry URL is HTTPS on the manifest URL's own host, compared without case, with no user, password or port. A manifest that points anywhere else is rejected whole.
- Ids and file names become paths on disk, so their shape is checked. Region and base pack ids are lowercase kebab-case of at most 64 characters, unique among regions and among base packs. File names are kebab-case with a `.v<N>.` version and an extension, at most 128 characters, unique across the manifest, and never end in `.resume`. `bytes` lies between 1 and the 1.9 GiB asset limit, `sha256` is 64 lowercase hex digits, `data_date` is a real calendar date, a bbox is four finite numbers in range with its minimum below its maximum, and attribution URLs are HTTPS.
- Error messages name a field path, never document content or a URL.
- Unknown fields, unknown layer keys and entries with an unknown `role` are ignored, as the compatibility rule says. The schema versions the package reads are one table, `ReadableVersions.table`, today `[1]` for every layer ([`ReadableVersions.swift`](../Sources/MaqsCore/Manifest/ReadableVersions.swift)). It is the client half of ADR 0012's rule.

For `sources.json` ([`SourcesDocument.swift`](../Sources/MaqsCore/Network/SourcesDocument.swift)), `sources_version` must be 1, every URL is HTTPS with a host and no credentials, the tile template holds `{z}`, `{x}` and `{y}`, and each layer has at least one source in a form the package decodes: Shortbread 1.0 MVT for the basemap, terrarium WebP or PNG at 256 or 512 px for terrain. A rejected file leaves the last good copy in use, the cached copy first and then the one bundled in the package (`Sources/MaqsCore/Resources/sources.json`, a byte copy of `config/sources.json` that `swift.yml` checks with `cmp`).

**Refresh.** `.ifStale` uses the cached manifest while it is less than `catalogMaxAge` old, 24 hours by default. A cache stamped in the future, after the clock moved back, counts as stale. `.always` sends `If-None-Match` with the cached ETag, and a 304 renews the fetch date. The package never fetches on a timer and never retries inside a call. A 429 is `rateLimited`, another status is `network(statusCode:)`, a transport error is `network(statusCode: nil)`, and the app decides when to try again. A cancelled refresh throws `CancellationError` and leaves `lastRefreshError` alone. After a successful refresh, while no install is queued or running, downloads whose SHA-256 the new manifest no longer lists are deleted.

**Storage.** The root is `Application Support/Maqs/`, excluded from backup:

```
manifest.json  manifest.meta.json             # cached manifest; its ETag and fetch date
sources.json   sources.meta.json
packs/region-<id>/pack.json                   # or base-<id>; readers trust only the files it names
packs/region-<id>/<layer>/<sha256>/<file>     # installed files, addressed by content
downloads/<sha256>-<file>                     # partial and completed downloads
downloads/<sha256>-<file>.resume              # resume data
```

An update never overwrites a file the live `pack.json` names. New files go to new `<sha256>` directories, and `pack.json` is written last, atomically, as JSON with sorted keys, ISO 8601 dates and layers keyed by name (a golden test pins the format). A crash leaves either the old record and its files or the new record and its files. The launch sweep runs in `Maqs.init` only. It deletes a pack directory that has no `pack.json`, which is an interrupted first install or removal. It keeps one whose `pack.json` exists but cannot be read, because iOS data protection can hide a file before the first unlock. Otherwise it deletes the files the record does not name. After an install only that pack is swept. Pack ids are checked with the manifest's rule at every public entry point, so an invalid id never becomes a path. There is no `fsync`: `rename(2)` covers a process crash, but not a power loss or a kernel panic on APFS, and that is accepted.

**Downloads and install.** Installs run one pack at a time, in call order. A second `install` of a pack that is queued or running joins it, and an install plans again when its turn comes, because a refresh may have replaced the manifest meanwhile. Each pack downloads at most two files at once. `DownloadSession` is delegate-driven, so it works with a background session. Downloads are keyed by content (`<sha256>-<file>`): the destination, the resume data and the task description all derive from the key, a second request for a running key joins it (also a task the system reconnected after a relaunch), and a completed leftover is reused after a size and hash check. Resume data is kept on cancel and on failure and used once, only for the same URL. A fresh task must answer 200, a resumed one 200 or 206, and an error body never lands on disk. Every file is checked for its size, then its SHA-256 in 1 MiB reads, before any file moves; a mismatch deletes the download and installs nothing. Progress reaches `MaqsState` at most once per 256 KiB and per 100 ms, always with the final value, and never goes backwards. `cancelInstall` restores the pack's previous state and the install throws `cancelled`. `remove` cancels a running install, waits for it, then deletes the pack and its leftover downloads. A 429 fails the install, and the package does not retry it.

On iOS the app forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `Maqs.handleEventsForBackgroundURLSession(identifier:completionHandler:)`. The package calls the handler once, on the main thread, when it has both the handler and the session's "events finished" callback, in whichever order they arrive. A process creates one `Maqs`, never two with the same background identifier, because the system allows one background session per identifier. Unsandboxed macOS processes share `~/Library/Application Support/Maqs` unless they set `storageDirectory`.

**Verified on 2026-10-16 and 2026-10-17.**

| Fact | Verified value | Source |
|---|---|---|
| Tools version and warnings | `swift-tools-version: 6.2` and `.treatAllWarnings(as: .error)` work with Xcode 27 and Swift 6.4; an unused variable fails the build | local build |
| Resources outside `Sources/` | a target with `path: "Tests/MaqsTestSupport"`, `sources: ["Sources"]` and `resources: [.copy("Fixtures")]` builds, and `Bundle.module` finds the files | local build |
| `releases/latest/download/manifest.json` | 302, 302, then 200 from `release-assets.githubusercontent.com` with a strong `ETag`; a repeat with `If-None-Match` answers 304 | `curl -sIL` |
| `macos-latest` runner | macOS 26 arm64, Xcode 26.6 by default, simulators include `iPhone 17` | actions/runner-images README and its macos-26-arm64 readme |
| Xcode scheme | `Maqs` while the package has one library product, `Maqs-Package` once it has several. `swift.yml` reads `xcodebuild -list -json`, uses `Maqs-Package` when it is listed and `Maqs` otherwise, and fails the step when the listing fails or the chosen scheme is not listed | `xcodebuild -list`, Xcode 27 |
| `swift test --filter` | the suite name alone selects a suite (`ManifestTests`, or `ManifestTests/decodesFixture` for one test); `MaqsCoreTests/ManifestTests` matches nothing | local run |
| Swift Testing count | a parametrized test counts once in "Test run with N tests" | local run |
| Exit tests | `#expect(processExitsWith:)` is unavailable on the iOS Simulator, so the one exit test is `#if os(macOS)` | local simulator build |
| iOS Simulator leg | `iPhone 18 Pro` with Xcode 27: 162 tests pass; `swift test` on macOS runs 163, the extra one being the exit test | local `xcodebuild test`, 2026-10-17 |
| Resume data | `downloadTask(withResumeData:)` raises an Objective-C exception that Swift cannot catch on bytes it cannot parse (not a property list, or a value of the wrong type), so `DownloadSession` checks the blob and deletes it before use | local tests |
| Background `URLSession` | delegate-based tasks only; move the file before `didFinishDownloadingTo` returns; resume data is in the error's `NSURLSessionDownloadTaskResumeData`; call the stored completion handler from `urlSessionDidFinishEvents` on the main thread | Apple, "Downloading files in the background", via Context7 |

**Rejected.**
- Separate public components wired by the app: more public types to keep stable, and every app rebuilding the install invariants.
- Building the fixtures in CI, or downloading the pipeline's artifact as ADR 0009 planned: a Python toolchain or a download before every `swift test`, and no test run from a clean checkout.
- Persisting the bundled base pack registration: a stale path after an app update.
- Retrying inside the package: the app decides when to try again, and a 429 must never become a tight loop.
- An empty `sources.json` as the opt-out: it fails the schema, and it would be a file on `main` shared by every app, where the opt-out is one app's choice.

**CONTRADICTS BRIEF (minor):** the brief says "Build outputs never get committed to git; they go to Releases only" and "Never commit generated data". The `test` region's outputs under `Tests/MaqsTestSupport/Fixtures/` are committed (decision 4), capped at 8 MB and never released, so that `swift test` runs from a clean checkout. Release data still goes only to Releases.

**CONTRADICTS CLAUDE.md (minor):** CLAUDE.md said that generated data never goes in git and that the bundled `sources.json` is "synced by the build". The fixtures are the one exception to the first. The bundled copy is made by `scripts/update-fixtures.sh` and checked by CI, because SwiftPM cannot copy a file from outside a target at build time. CLAUDE.md now says both.

**Consequences.**
- Apps call `refreshCatalog()` when they want fresh data, read `MaqsState` and show the catalog statuses themselves.
- `MaqsTerrain` (sub-project 2) and `MaqsData` (sub-project 3) open `InstalledFile.url`s and never import `MaqsCore`. `MaqsData` must open SQLite files read-only and immutable, so no `-wal` or `-shm` file appears for the sweep to delete.
- An update deletes the files it replaces at once. An app reads `installedPack(_:)` again after `install` returns, because a URL it has not opened yet may be gone; an open file stays readable until it is closed.
- The package is not tagged until sub-project 4, and `v0.1.0` will be a git tag or a release created with `--latest=false` (ADR 0013).
- `swift.yml` runs only on package changes, so data-only and docs-only pushes spend no macOS minutes. The runner facts above come from the image documentation; the workflow's first run on GitHub checks them.
- Not verified: whether `URLSession` sends `If-None-Match` again after GitHub's redirect (at worst every `.always` refresh downloads the whole manifest, about 16 KB); whether GitHub's asset host answers a resumed download with 206; and whether resume data survives the signed redirect URL. If it does not, the blob is discarded and the download starts over, never with wrong data.
- After a relaunch, a pack whose background download finished while the app was not running is installed only when the app calls `install` again, because the package does not remember which packs the user asked for. That call joins a transfer that is still running, or reuses the finished file after a size and hash check, so the file is not downloaded again.
- Decided before `v0.1.0` (sub-project 4): persisting install intents, or exposing pending transfers, so that the app need not remember them; an explicit `Codable` shape for `PackID` in `pack.json`; a public `MaqsState` initializer for SwiftUI previews; a `PackState` that keeps the installed pack visible while it updates or after a failed update; that `remove` of a bundled pack leaves in place a downloaded record with the same id; and that `remove` does not cancel a background transfer restored after a relaunch that no caller has joined.
- Deferred to later sub-projects: power-loss durability (no `fsync`); a `downloading` state for a background transfer the system reconnects after a relaunch, which today shows only when `install` is called again; and caching in `onlineSources`, which reads the `sources.json` file on every call, so `MaqsUI` should read it once rather than per tile.

---

## 0015 — `MaqsTerrain`: elevation, profiles and line of sight

**Date:** 2026-10-26 · **Status:** accepted (owner decisions 2026-10-24 to 2026-10-26)

**Context.** `MaqsTerrain` is the second of the four sub-projects of Phase 4 (ADR 0014). It answers how high the ground is at any coordinate, from the terrain archives of installed regions or from VersaTiles' online tiles outside them. It uses neither MapLibre nor `MaqsCore`, so an app that needs only elevation links this product alone. Line of sight sets the requirements: from where the user stands, which of the peaks around them can they see? `MaqsData` will supply the candidate peaks along a bearing, and `MaqsTerrain` decides which of them are visible. It is the only use that needs earth-curvature and refraction corrections and sight lines across many tiles. Spot elevations, routes and grids (ADR 0008) use the same sampler. ADR 0014 left open how the product receives the online provider values, because `TileSource` is a `MaqsCore` type.

**Decisions.**
1. The visibility query is part of `MaqsTerrain`. Left to the apps, each would rewrite the occlusion test and its edge cases (missing ground, the summit's real height, the target's own slope), and they would disagree.
2. The range is a parameter, `maxDistance`, 100 km by default. A peak beyond it is `outOfRange`; a peak the terrain hides is `hidden`.
3. Visibility is computed once, when the user stops and looks. There is no live sweep. A live mode, a horizon precomputed per position and queried by bearing, can come later as a new method without changing this API.
4. The answer leans toward visible, because leaving out a peak the user can plainly see is worse than naming one that is just hidden. Ground hides a target only when it rises above the sight line by more than `margin`, 10 m by default, about the terrain's vertical error.
5. The sight line aims at the true summit. z12 terrain (about 13.3 m per pixel at 46° N) flattens summits, so when the app passes a target's real height (`SightTarget.elevation`, the OSM `ele` that `MaqsData` will provide), the line aims at that height, and otherwise at the sampled ground.
6. The target's own slope is ignored: the last `targetClearance` metres before the target, 150 by default, are not tested.
7. The observer's eye is 1.7 m above the ground by default (`ObserverHeight.aboveGround`), or at an absolute height (`.absolute`).
8. When ground is missing along the line and no known ground hides the target, the answer is `unknown`, never `visible`. The app decides whether to show such peaks.
9. No dependency on `MaqsData` or `MaqsCore`. The inputs are coordinates, optional heights and file URLs.
10. Distant ground comes from coarser tiles: z12 out to 10 km, z11 to 30 km, z10 to 40 km and z9 beyond (`ZoomBands.standard`), for local and online data alike. A full look then needs about 69 tiles instead of 743 (*Verified*, below). Distant ridges come out slightly lower, which errs toward visible. The bands are a parameter.
11. The privacy cost of an online look is accepted and documented (*Privacy*, below). Apps with a strict privacy stance use the online opt-out. The request pattern does not try to hide the observer.
12. There is no `ascentDescent` helper. The brief does not ask for one, and it can be added later without breaking anything.

**Online source.** `MaqsTerrain` defines its own value type, `OnlineTerrainSource`, with the tile template, format, tile size and zoom range, and never sees a `MaqsCore` type. The app maps a `TileSource` to it in a few lines, which the README shows. This closes ADR 0014's open question for terrain; the question for `MaqsUI` stays open. The initializer throws `TerrainError.invalidConfiguration` unless the template is HTTPS with a host, has no credentials and has the placeholders `{z}`, `{x}` and `{y}` and no other; the format must be `webp` or `png`, the tile size 256 or 512, and `0 <= minZoom <= maxZoom <= 22`. When the app turns online tiles off, `Maqs.onlineSources` is nil, so an app that follows the README builds no online source and `MaqsTerrain` sends no request (ADRs 0008 and 0014).

**Sampling.** Every elevation follows the pipeline's rule, which [`data-format.md`](data-format.md#elevation-sampling) states once for both. The tests compare the two implementations at 625 points of the `test` region, to 1e-6 m. The zoom depends on the call:
- `elevation(at:)` and `elevations(at:)` read the finest zoom a source has at the point: z13 where a `terrain-hd` archive covers it, z12 elsewhere.
- `grid` reads the coarsest zoom whose pixel, at the area's centre latitude, is at most half the cell spacing, so a large area decodes a few tiles instead of hundreds.
- `profile` and `visibility` read the zoom of the band the distance from the start or the observer falls in, capped at the finest zoom a source has. Samples lie one 512 px pixel apart at that zoom, measured at the start latitude, unless a profile sets `step`.

The sources are tried in order: local archives first, the one with the highest maximum zoom first, then the online source. A tile missing from an archive falls through to the next source. A first pass skips sources whose minimum zoom is above the zoom the call needs, so a `terrain-hd` archive that starts at z13 is not read for a z12 band. When no source covers the point, the skipped sources are tried at their minimum zoom, so data that exists is used. Where a local archive covers a point at the zoom a call needs, the call makes no online request for it, even when the online source has finer zooms, because inside an installed region the budget is zero network calls.

`Terrain.init` and `setArchives(_:)` open the archives and validate the header, the root directory and the metadata. The tile type must be 2 (PNG) or 4 (WebP), `tile_schema` must be `dem/terrarium` when the metadata has one, and `tile_size` must be 256 or 512 when the metadata has one, the sizes `OnlineTerrainSource` accepts; without it 512 is assumed. Any other archive is `TerrainError.notTerrain`. A size of 0 would divide by zero where a call sizes its batches of tiles, and a huge one would overflow where a tile's pixels are counted. The reader opens MVT (1) and MapLibre Vector Tile (6) archives too, and its tests read the basemap fixture, but they are not elevation sources. A call running when `setArchives` swaps the archives finishes the batch of tiles that was loading with the archives it was located in, and does not cache that batch. Its later batches are located again with the new archives and cache normally: a visibility look locates each batch's sight lines when it builds the batch, and the other calls locate their remaining points again after the swap.

**Visibility.** For each target, in input order:
1. The great-circle distance from the observer. Beyond `maxDistance` the target is `.outOfRange`.
2. The eye height: the ground at the observer plus the `aboveGround` value, or the `absolute` value. Without ground at the observer, every target in range is `.unknown(at: .observer)`.
3. The target's height: `SightTarget.elevation`, else the ground at the target. Without either it is `.unknown(at: .target)`.
4. The ground along the great circle from one step out to `distance − targetClearance`. A sample at distance `d` has the apparent height `ground − d² / (2R) × (1 − k)`; `EarthModel` defaults to `R` = 6,371,008.8 m and `k` = 0.13, and `.none` turns both corrections off.
5. The sight line runs from the eye to the target's apparent height. If any known sample rises above it by more than `margin`, the target is `.hidden`, at the sample with the largest clearance, which the result carries.
6. Otherwise, if any sample had no data, the target is `.unknown(at: .path)` with the reason of the first gap.
7. Otherwise it is `.visible`, with its distance, bearing and an elevation angle corrected for curvature and refraction, so an app can place a label on screen.

A known ridge outweighs a gap elsewhere, so a target known to be hidden is never `unknown`. A target less than a metre away is visible, and one whose coordinate is not a valid position is `.unknown(at: .target)`. The drop at 10 km is 7.848 m with `k` = 0 and 6.828 m with `k` = 0.13; at 100 km it is 784.8 m and 682.8 m. The tests use these values. Targets are processed in bearing order, in batches of at most 64 whose tiles fit `memoryCacheBytes`, so neighbouring sight lines share tiles and a full look decodes each tile about once.

**Results and errors.** Every sample is an `ElevationSample`: `.elevation(metres)` or `.missing(MissingReason)`. The reasons are `noData` (no source covers the point, or the online source answered 404), `rateLimited` (the online cool-down), `networkFailure` (another status, a transport error, or a body that is not a tile of the source's size) and `requestCap` (the call reached its online cap). A failure of the network is never reported as `noData`, so an app can tell "nothing here" from "try again in a minute", and a route or a grid keeps its local values while some online tiles fail. Local corruption throws, because it is a broken install the app should surface: `PMTilesError` (`notPMTiles`, `unsupportedVersion`, `unsupportedCompression`, `truncated`, `corruptDirectory`, `corruptCompressedData` for bad gzip, `sectionTooLarge`, `nestedLeafDirectory`, `unreadableFile`) or `TerrainError` (`invalidConfiguration`, `notTerrain`, `undecodableTile`, `invalidArea`, and `invalidInput` for input outside the bounds). The bounds keep one call from asking for unbounded work: a `TerrainArea` spans at most 2° on each side, a grid has 1 to 1,024 cells on each side, a profile step is at least 1 m and a profile at most 100,000 points, a look takes at most 5,000 targets and 100,000 samples per sight line, and the observer and the options must be finite: an `EarthModel` has a radius above 0, `.infinity` for a flat Earth, and a finite refraction, checked by `profile` and `visibility` before they read a tile. A cancelled call throws `CancellationError`. Each `errorDescription` says what to do.

**Caches.** Decoded tiles are kept as Float32 elevations, 1 MiB per 512 px tile, in an LRU bounded by `memoryCacheBytes`, 64 MiB by default; `setArchives` empties it. Every call loads its tiles in batches of as many as fit `memoryCacheBytes`, at least one, and samples each batch before it loads the next, so it holds the cache and one batch, about twice `memoryCacheBytes`, however many tiles it needs. `elevations(at:)`, `grid` and `profile` group their points by tile, in the order the input first needs them, so the neighbouring points of a route share a batch; a visibility look builds its batches from sight lines. All the batches of a call draw on its one online cap of 128. Online tile bytes go to a `URLCache` of `diskCacheBytes`, 64 MiB by default, in the app's Caches directory (`Maqs/terrain-tiles`). URLSession stores a response on disk only when it is at most about 5 % of the disk capacity, so `diskCacheBytes` must stay well above 20 times the largest tile; tiles weigh about 120–215 KB. Each archive keeps its decoded leaf directories in a 16-entry LRU.

**Online tiles.** VersaTiles is a free demo server whose rate limit answers 429 with no `Retry-After` (ADR 0001), so the etiquette is in the code:
- Each `Terrain` has one `URLSession`, made from a copy of the configuration it is given, with its own `URLCache` and `.useProtocolCachePolicy`. The server's six-hour `Cache-Control` decides, and a repeated look within it sends no request. No request carries a header that disables caching.
- The `User-Agent` is the app's string followed by `Maqs/<version>`, and `Terrain.init` throws when an online source is set and the app's string is blank. `MaqsTerrain` keeps its own copy of the version (`TerrainVersion.string`) because it never imports `MaqsCore`, and the `guards` job of `swift.yml` fails when it differs from `MaqsVersion.string`.
- Requests go out only for tiles no local archive has, at most four at once, and one per tile however many callers wait for it. When every caller waiting for a tile has been cancelled before its request is sent, the request is skipped; a request already sent completes and its result is dropped.
- A 429 stops every request to the online source for 60 s, and each further 429 doubles the pause, up to 900 s. A 429 that arrives during a pause answers a request sent before the pause began, so it is ignored: a burst of four 429s makes one pause of 60 s, not 480 s. For the same reason a success during a pause neither ends it nor resets the doubling. The first success after a pause sets the next one back to 60 s. During a pause online tiles are `.rateLimited`, and nothing retries inside a call.
- A call fetches at most 128 tiles online, and ground beyond that is `.requestCap`, so an app that passes thousands of targets or a large grid cannot flood the provider. A full look needs about 69.
- A 404 is `.noData` for that call. The package does not remember it, and URLSession caches only 2xx responses, so the next call asks again.
- The log (`os.Logger`, category `terrain`) has one line per request with its status and byte count, a line for each skipped request, and the start and end of each pause. Tile coordinates are logged `privacy: .private`; no full URL and no tile content is logged. There is no cache-hit field, which would need a `URLSessionTaskMetrics` delegate, so a 200 that came from the local `URLCache` looks the same as one the server sent. An archive that fails to open, at `Terrain.init` or `setArchives`, is logged with its file name and the error case, without the URL, and the error is still thrown to the app. As for `MaqsCore`, there is no metrics API: the signals are the log and the reasons in the results.

The cool-down lengths and the cap of 128 are guesses at a safe pace. VersaTiles does not publish its limit, and neither number has been tried against the server.

Cost: a full 360° look out to 100 km with nothing installed takes about 69 requests, roughly 11 MB at the fixture's tile sizes, and the cache makes that once per six hours for one area. Inside an installed region a look requests only the ground beyond the pack's border.

**Privacy.** A tile request carries tile coordinates, not the position, but the tiles of one look form a ring centred on the observer. A rough estimate, not a measurement, puts the observer within a cell of about 0.2 km² (about 500 m across) given the full set of one look, and within about 1 km given its z12 tiles alone. An app weighing the privacy cost should use this figure rather than the size of one tile. Apps with a strict privacy stance set `onlineTiles` to false in `MaqsCore`: `Maqs.onlineSources` is then nil, the app builds no `OnlineTerrainSource`, and the package sends nothing.

**PMTiles reader.** Internal, minimal and defensive, it mirrors `pipeline/src/maqs/pmtiles_header.py` and `pmtiles_reader.py`. It holds one descriptor (`O_RDONLY | O_CLOEXEC`) for the archive's lifetime and reads with `pread`, so a pack that `MaqsCore` removes meanwhile stays readable, and a file truncated underneath it is `PMTilesError.truncated`. Every offset and length is checked against the file and its sections before a read, a directory's entry count against its bytes before any allocation (at least four bytes per entry), and varints are at most ten bytes long. The caps are 16 MiB per directory, 64 MiB per tile and 8 MiB of metadata, after inflation too. It follows one level of leaf directories and rejects a nested leaf. An unsupported tile or internal compression fails when the archive opens. For gzip, Compression's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) and `compression_stream_process` does not report where the stream ended. So the reader parses the RFC 1952 header itself, with its optional `FEXTRA`, `FNAME`, `FCOMMENT` and `FHCRC` fields, and takes as the trailer the first position after the header whose 8 bytes equal the output's CRC-32 and length. It ignores bytes after the member, as zlib does for the pipeline.

**Package.** `MaqsTerrain` is a second library product with no dependency. It imports Foundation, CoreLocation (for `CLLocationCoordinate2D`), CoreGraphics, ImageIO, Compression, Synchronization and os. The test target `MaqsTerrainTests` depends on `MaqsTerrain` and `MaqsTestSupport`. `MaqsTestSupport` no longer declares a dependency on `MaqsCore`, which none of its sources used, so the terrain tests do not build `MaqsCore`; it gains `StubGate`, which holds a stub response until the test releases it. With two library products the Xcode scheme is `Maqs-Package`, which `swift.yml` already picks. `Tests/MaqsTestSupport/Fixtures/test/terrain-golden.json` holds Hilbert tile ids, the SHA-256 of each fixture tile and the elevations on a 25 × 25 grid over the fixture, all from the pipeline's reader and sampler (`maqs.terrain_golden`). `scripts/update-terrain-golden.sh` writes it, and `scripts/update-fixtures.sh` runs that script, so the fixtures and the golden values are regenerated together.

**Verified on 2026-10-25 and 2026-10-26.**

| Fact | Verified value | Source |
|---|---|---|
| Fixture tiles | the `test` region's terrain tiles are lossless WebP (a `VP8L` chunk in every tile), so decoded values are exact; about 105 KB per tile on average, 118–215 KB for the z10–z12 tiles over the Nevegal mountains | the fixture archive |
| ImageIO and Pillow | on macOS 27 with Swift 6.4 the decoded `CGImage` has 8 bits per component, 32 bits per pixel, alpha `noneSkipLast` and the sRGB colour space; its provider bytes and an RGBA8 redraw both match Pillow at five sampled pixels of tile 12/2187/1455. On the iOS Simulator the full-look measurement below decodes the fixture tile; the comparison with the pipeline's values runs there in the `ios-simulator` leg of `swift.yml` | local probe |
| Compression | `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) | the SDK's `compression.h` |
| `CLLocationCoordinate2D` | `Sendable` in the macOS and iOS Simulator SDKs, so the public types that hold one are `Sendable` under strict concurrency | local builds |
| Documentation | Context7 indexes neither Compression nor ImageIO; the SDK header and the probe above are the sources | Context7 |
| URLCache | a response is cached only with a status in the 200–299 range and, with a disk cache, only when it is "no larger than about 5% of the disk cache size" | Apple, `urlSession(_:dataTask:willCacheResponse:completionHandler:)`, via Context7 |
| Tile counts | a full 360° look out to 100 km from Nevegal, with rays every 1° and samples every 10 m, touches 743 tiles at z12 only; 93 with bands 12/11/10 at 10/30 km; 69 with the shipped bands (12 at z12, 23 at z11, 15 at z10, 19 at z9); 50 if the inner bands also tighten to 5 and 15 km | a count over the bands |
| `swift test` | prints one `Test run with N tests` line per test target, `MaqsTerrainTests` and then `MaqsCoreTests` | local run |
| Time limits | Swift Testing's `.timeLimit` cancels only the test's own task, so a polling loop (`Task.yield`) without `Task.checkCancellation()` hangs the whole run instead of failing | local run |
| Release builds | `swift test -c release` fails, because the test targets use `@testable import`, which needs testability | local run |

**Measurements (debug builds).** A full look is 200 targets at 10–100 km in every direction, with each tile decoded from the fixture's z12 WebP tile (`FullLookMeasurement`, which prints the numbers and asserts nothing about time).

| Where | Time | Decodes | Peak tile cache |
|---|---|---|---|
| macOS, local Mac, the test run alone | 1.30–1.33 s warm; 4.29 s on one cold first run | 55 | 57,671,680 bytes (55 MiB, sampled) |
| iOS Simulator, iPhone 18 Pro, the test run alone | 2.59 s on the first run, 2.38 s warm | 55 | the same |

The target of about 2 s for a full look on local data is met on macOS and missed on the simulator in a debug build. Decoding already runs in parallel. Release builds cannot run the `@testable` tests, so the device and release-build numbers wait for the demo app (sub-project 4). The time is not a CI assertion, because runner timings vary.

**Correction to ADR 0008.** Decision 5 of ADR 0008 puts z12 at "~27 m per pixel at 46° N". With 512 px tiles it is about 13.3 m, and a z12 tile is about 6.8 km wide there; ADR 0009 noted the same. ADR 0008's status line now points here.

**Rejected.**
- A raw sampler only, with the visibility test left to the apps: a smaller package, but every app would rewrite the same occlusion test and its edge cases, and they would disagree.
- Precomputing visibility in the pipeline: it depends on the observer's position, which is personal data and never leaves the device.
- z12 along the whole sight line: 743 tiles for a full look instead of 69.
- Memory-mapping the archives: a mapped file that is truncated underneath faults on access, where a positioned read returns fewer bytes and the reader reports `truncated`.
- Hiding the observer in the request pattern, for example with extra tiles around the ring: it adds requests to a free server on every look, and the opt-out already serves the apps that need more.
- Retrying online requests inside a call: a 429 must never turn into a tight loop, and the app decides when to look again.

**Consequences.**
- `MaqsData` (sub-project 3) supplies the candidate peaks along a bearing with their `ele`, and the app passes them to `visibility(of:from:options:)` as `SightTarget`s.
- After an install, an update or a removal, the app reads `installedPack(_:)` again and passes the terrain file URLs to `setArchives(_:)`. An archive that is already open stays readable after `MaqsCore` deletes its file, until `setArchives` or the end of the `Terrain` closes it.
- A version bump changes both `MaqsVersion.string` and `TerrainVersion.string`; CI fails when they differ.
- A live sweep, a public PMTiles reader and an `ascentDescent` helper can each be added later without changing this API.
- Not verified: whether the cool-down and the cap suit VersaTiles' real limit; the device and release-build timings; and the peak memory on older iPhones with the 64 MiB default, which is a parameter. The demo app (sub-project 4) measures the last two.
- Still open from ADR 0014: whether `MaqsUI` depends on `MaqsCore`, and how it receives the online provider values.
