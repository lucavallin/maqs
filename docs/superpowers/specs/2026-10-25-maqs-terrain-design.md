# Swift package, sub-project 2: `MaqsTerrain` — design

**Date:** 2026-10-25 · **Status:** approved by the owner 2026-10-26
**Brief:** `docs/BRIEF.md` § Phase 4, MaqsTerrain · **Builds on:** ADR 0008 (terrain API shape, online opt-out, privacy), 0011 (the pipeline's sampling and ascent rules), 0012 (`sources.json`), 0014 (`MaqsCore`; the open question of how `MaqsTerrain` gets online provider values)

## Problem

`MaqsTerrain` answers "how high is the ground here?" for any coordinate. It reads the terrarium tiles of an installed region's PMTiles file, or VersaTiles' online tiles outside installed regions, with no MapLibre and no `MaqsCore`. An app that needs only elevation links this product alone.

**The use that sets the requirements is line of sight** (owner, 2026-10-24): from where the user stands, which of the peaks around them can they see? `MaqsData` (sub-project 3) supplies the candidate peaks along a bearing; `MaqsTerrain` decides which are visible. It is the only use that needs earth-curvature and refraction corrections and long sight lines across many tiles. Spot elevation, batch sampling along a route and grid sampling (ADR 0008) reuse the same sampler.

## Approaches considered

1. **Raw sampler only**: point, batch, grid and profile, with the visibility test left to each app. Smallest package, but every app rewrites the same occlusion math and its edge cases (unknown ground, summit height, the target's own slope), and they disagree.
2. **Sampler plus a visibility query** (chosen): the package also answers "visible, hidden or unknown" for a list of targets. About a hundred more lines, one tested definition.
3. **Do nothing in Swift**: precompute visibility in the pipeline. Rejected: visibility depends on the observer's position, which is personal data (CLAUDE.md data classification) and never leaves the device.

## Decisions

Made by the owner in conversation (2026-10-24 to 26):

1. **Line of sight drives the design.** The visibility query is part of `MaqsTerrain`.
2. **Range is configurable; the default keeps only what the eye can see.** A peak the terrain hides is not visible, and neither is one beyond the maximum distance, 100 km by default.
3. **Compute once, when the user stops and looks.** No live sweep now. A live mode (a precomputed horizon per position, queried by bearing) may come later and must be addable without breaking this API.
4. **Lean toward visible.** Leaving out a peak the user can plainly see is worse than naming one that is just hidden. A ridge hides a target only when it clears the sight line by more than a margin.
5. **Aim at the true summit.** z12 terrain (about 13 m per pixel at 46° N) flattens summits, so when the app knows a target's real height (OSM `ele`, from `MaqsData`) the sight line aims at it; otherwise at the sampled ground.
6. **Ignore the target's own slope.** A short stretch before the target is not tested for occlusion.
7. **The observer's eye is above the ground,** 1.7 m by default, a parameter.
8. **Unknown stays unknown.** When ground data is missing along the line and no known ground hides the target, the result is `unknown`, never `visible`. The app decides whether to show unknown peaks.
9. **No dependency on `MaqsData` or `MaqsCore`.** Inputs are plain coordinates, optional heights and file URLs.
10. **Coarser data for distant ground.** z12 out to 10 km, z11 out to 30 km, z10 out to 40 km, z9 beyond, for local and online data alike, so a full look needs about 69 tiles instead of 743. Distant ridges come out slightly lower, which errs toward visible (decision 4). The bands are a parameter.
11. **The privacy cost of an online look is accepted and documented.** The set of tiles one look requests locates the observer to roughly 500 m (see *Online tiles*); `docs/architecture.md` and ADR 0015 state that figure. Apps with a strict privacy stance use the online opt-out (ADR 0008). No mitigation in the request pattern.
12. **No `ascentDescent` helper** in this sub-project: it is not in the brief, and it can be added later without breaking anything.

The builder's calls are marked *(builder's call)* where they appear; anything not marked is required.

## Success criteria

- `MaqsTerrain` is a product with no dependency; it imports only system frameworks (Foundation, ImageIO, CoreGraphics, Compression, CoreLocation for `CLLocationCoordinate2D`, os, Synchronization if needed). It builds for iOS 18 and macOS 15 with warnings as errors.
- The PMTiles reader opens every fixture archive, returns the same tile bytes as the pipeline's reader (`pipeline/src/maqs/pmtiles_reader.py`) for the same `z/x/y`, and turns every truncated, corrupt or hostile input in the test list into a typed `PMTilesError`: no crash, no trap, no allocation driven by an unchecked length.
- Point sampling over the `test` region agrees with the pipeline's `TerrainSampler` to 1e-6 m at every coordinate of a golden file the fixtures script generates.
- The visibility query returns `visible`, `hidden` and `unknown` as specified below over synthetic terrain with known answers, and applies curvature and refraction with the formula below.
- Online: no request is made when no online source is configured; every request carries the app's User-Agent plus the package token and no `Cache-Control: no-cache` or `Pragma`; a 429 stops all online requests for a cool-down and the affected results are `unknown(.rateLimited)`; at most four requests run at once; one tile is fetched once even when many callers want it.
- The decoded-tile memory cache never exceeds its byte bound.
- `swift test` and the iOS Simulator leg in `swift.yml` pass, the latter including ImageIO WebP decoding on the simulator.
- Every public symbol has a DocC comment. ADR 0015 records the decisions and the facts below, with dates.

## Facts verified while designing (2026-10-25)

- The `test` fixture's terrain tiles are **lossless WebP** (`VP8L` chunk, every tile), so decoded RGB values are exact. Average tile size about 105 KB; z10–z12 tiles over the Nevegal mountains are 118–215 KB.
- **ImageIO decodes them byte for byte like the pipeline's Pillow**, on macOS 27 with Swift 6.4: the decoded `CGImage` is 8 bits per component, 32 bits per pixel, alpha `noneSkipLast`, colour space sRGB, and its provider bytes and an sRGB RGBA8 redraw both match Pillow at five sampled pixels of tile 12/2187/1455. Not yet checked on the iOS Simulator; the simulator test leg covers it.
- **`COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951)** per the SDK's `compression.h`. PMTiles gzip sections are RFC 1952: the reader parses and skips the gzip header (with its optional `FEXTRA`, `FNAME`, `FCOMMENT`, `FHCRC` fields), inflates the body with Compression, and checks the trailer's CRC-32 and length.
- Context7 indexes neither Compression nor ImageIO; the SDK header and the probe above are the sources.
- ADR 0008 says z12 is "~27 m per pixel at 46° N"; with 512 px tiles it is about 13.3 m (CLAUDE.md has it right). ADR 0015 records the correction.
- A full 360° look out to 100 km from Nevegal (rays at 1°, samples every 10 m) touches 743 tiles at z12 only; 93 with bands 12/11/10 at 10/30 km; **69 with decision 10's bands** (12 at z12, 23 at z11, 15 at z10, 19 at z9); 50 if the inner bands also tighten to 5 and 15 km.

## Package layout

```
Package.swift                              # + product MaqsTerrain, target MaqsTerrain, test target MaqsTerrainTests
Sources/MaqsTerrain/                       # the product
Tests/MaqsTerrainTests/<Type>Tests.swift
Tests/MaqsTestSupport/                     # reused: fixture URLs, StubServer, temporary directories
Tests/MaqsTestSupport/Fixtures/test/terrain-golden.json   # new, generated by scripts/update-fixtures.sh
```

`MaqsTerrainTests` depends on `MaqsTerrain` and `MaqsTestSupport`. `MaqsTestSupport` declares a dependency on `MaqsCore` that none of its sources use; dropping it keeps `MaqsCore` out of the terrain tests *(builder's call; keep it if something needs it)*. With two library products the Xcode scheme becomes `Maqs-Package`; `swift.yml` already picks it, and the CLAUDE.md command is updated.

## Public API

Spellings may be refined in the plan; shapes, defaults and semantics may not. All types `Sendable`.

```swift
/// A terrarium elevation source online, built by the app from MaqsCore's `TileSource`.
public struct OnlineTerrainSource: Sendable, Equatable {
    /// Throws `TerrainError.invalidConfiguration` unless the template is HTTPS with a host, no
    /// credentials, and `{z}`, `{x}`, `{y}`; format is "webp" or "png"; tile size is 256 or 512;
    /// 0 <= minZoom <= maxZoom <= 22.
    public init(tiles: String, format: String, tileSize: Int, minZoom: Int, maxZoom: Int) throws(TerrainError)
}

public struct TerrainConfiguration: Sendable {
    public var archives: [URL]                 // local terrain and terrain-hd PMTiles files, any order
    public var online: OnlineTerrainSource?    // nil: this instance never touches the network
    public var userAgent: String               // required (not blank) when `online` is set
    public var memoryCacheBytes: Int = 64 << 20   // decoded tiles
    public var diskCacheBytes: Int = 64 << 20     // URLCache for online tile bytes, under Caches/
    public init(archives: [URL], online: OnlineTerrainSource? = nil, userAgent: String = "")
    // internal test seams: URLSessionConfiguration (fresh copy per instance), clock
}

public actor Terrain {
    public init(configuration: TerrainConfiguration) throws        // opens and validates every archive
    public func setArchives(_ urls: [URL]) throws                  // after an install, update or remove
    public func elevation(at: CLLocationCoordinate2D) async throws -> Sample
    public func elevations(at: [CLLocationCoordinate2D]) async throws -> [Sample]     // a route, in order
    public func grid(_ area: TerrainArea, columns: Int, rows: Int) async throws -> ElevationGrid
    public func profile(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                        options: ProfileOptions = .init()) async throws -> ElevationProfile
    public func visibility(of targets: [SightTarget], from observer: Observer,
                           options: VisibilityOptions = .init()) async throws -> [Visibility]
}
```

The app maps MaqsCore's `TileSource` to `OnlineTerrainSource` in a few lines; the README shows them. This closes ADR 0014's open question for `MaqsTerrain`: the product defines its own value type and never sees a `MaqsCore` type. Because `Maqs.onlineSources` is `nil` when the app turned online tiles off, an app following the README builds no online source and `MaqsTerrain` makes no request (ADR 0008).

Supporting types *(names are the builder's call)*:

- `Sample`: `.elevation(Double)` (metres) or `.missing(MissingReason)`. `MissingReason` is `.noData` (no source covers the point: the documented empty result), `.rateLimited` (online cool-down), `.networkFailure` (online status, transport error or undecodable body) or `.requestCap` (the call's online tile cap was reached). A missing value is never `nil` and never pretends to be "no data" when the cause was the network, so an app can say "try again in a minute" (CLAUDE.md: "`throws`, never `nil` for a failure"). Every call uses it, so a route or a grid keeps its local values while some online tiles fail *(designer's call)*.
- `TerrainArea`: south-west and north-east corners; rejects inverted or non-finite corners and spans over 2° in either direction, so a grid cannot pull an unbounded number of tiles.
- `ElevationGrid`: `columns × rows` `Sample`s, row-major from the north-west corner, with the area.
- `EarthModel`: `radius` (default 6,371,008.8 m) and `refraction` coefficient `k` (default 0.13); `.none` turns both corrections off. Exposed as parameters, never constants (Swift package rule 8).
- `ZoomBands`: ordered `(upTo: metres, zoom:)` pairs; default `[(10_000, 12), (30_000, 11), (40_000, 10), (.infinity, 9)]`. A band's zoom is capped at the finest zoom a source has.
- `ProfileOptions`: `step` (default: the pixel size of the band in use), `earth`, `bands`.
- `ElevationProfile`: samples of `distance` (m along the great circle), `coordinate`, `ground: Sample` and `apparentElevation: Double?` (ground minus the curvature drop, `nil` exactly when `ground` is missing).
- `Observer`: `coordinate` and `height`: `.aboveGround(1.7)` by default, or `.absolute(metres)`.
- `SightTarget`: `coordinate` and an optional `elevation` (the true summit height).
- `VisibilityOptions`: `maxDistance` (100,000 m), `margin` (10 m, about the terrain's vertical error, *designer's call*), `targetClearance` (150 m, the stretch before the target not tested, *designer's call*), `earth`, `bands`.
- `Visibility`, one per target, in input order:
  - `.visible(distance:, bearing:, elevationAngle:)`, with the angle corrected for curvature and refraction, so an app can place a label on screen.
  - `.hidden(distance:, blockedAt: CLLocationCoordinate2D, blockedDistance:, clearance:)`, where `clearance` is how far the blocking ground rises above the sight line.
  - `.unknown(at:, reason: MissingReason, distance:)`, where `at` says which height was missing: `.observer`, `.target` or `.path`.
  - `.outOfRange(distance:)`.

`Terrain` is an actor so one instance owns its archives, its caches and its online state; parallel work inside a call (decoding several tiles) is the builder's call. A future live mode adds a method; nothing here needs to change.

## Sampling

One rule, the pipeline's (ADR 0011, `pipeline/src/maqs/osm/terrain_sampler.py`), now written once in `docs/data-format.md` § Elevation sampling and linked from the trails section:

- Web Mercator tile and pixel position of the coordinate at the chosen zoom; latitudes outside ±85.05° and non-finite coordinates have no data.
- Pixel centres at `+0.5`; bilinear interpolation between the four nearest centres **of the tile under the coordinate**, clamped at its edge; no interpolation across tiles.
- Terrarium: elevation = (R × 256 + G + B / 256) − 32768.

**Zoom.** `elevation(at:)` and `elevations(at:)` use the finest zoom any source has at that point: z13 when a `terrain-hd` archive covers it, else z12. `grid` uses the coarsest zoom whose pixel, at the area's centre latitude, is no larger than half the cell spacing, capped at the finest zoom available, so a contour card over a large area decodes a few tiles instead of hundreds *(designer's call)*. `profile` and `visibility` use the distance bands, measured from the start or the observer.

**Source order per tile.** Local archives first, finest maximum zoom first, then the online source. A tile missing from an archive's directory falls through to the next source. Where a local archive covers a point at the zoom a call needs, no online request is made for it, even when the online source has finer zooms: inside an installed region the budget is zero network calls (CLAUDE.md). Archives are opened at `init` and `setArchives`: header and root directory validated, `tile_type` 2 (PNG) or 4 (WebP), `tile_schema` `dem/terrarium` in the metadata when present; anything else is `TerrainError.notTerrain(URL)`. Archives with tile types 1 (MVT) and 6 (MLT) open in the reader, which reads them for its tests, but are not elevation sources.

**Decoding.** ImageIO, from the tile bytes. Use the provider bytes directly when the image is 8 bits per component RGB with or without a skipped or last alpha; otherwise draw into an RGBA8 context **in the image's own colour space**, so no colour conversion changes the values. A tile that is not square, not the source's tile size, or not decodable: local, `TerrainError.undecodableTile`; online, that tile has no data for the call (`.networkFailure`).

**Cache.** Decoded tiles in an LRU bounded by `memoryCacheBytes`; the representation (Float32 elevations, about 1 MiB per 512 px tile, or the raw RGB) is the builder's call. `visibility` processes targets in bearing order, so neighbouring sight lines reuse tiles.

## Visibility

For each target, in order:

1. Distance along the great circle from the observer. Beyond `maxDistance`: `.outOfRange`.
2. Observer height: the ground at the observer plus `aboveGround`, or the `absolute` value. No ground for `.aboveGround`: `.unknown(.observerUnknown)`.
3. Target height: `SightTarget.elevation`, else the ground at the target, else `.unknown(.targetUnknown)`.
4. Sample the great circle from the observer to `distance − targetClearance` with the profile's step and bands. Each sample's apparent height is `ground − d² / (2R) × (1 − k)`.
5. The sight line runs from the observer's height to the target's apparent height. If any known sample rises above it by more than `margin`, the result is `.hidden` at the sample with the largest clearance.
6. Otherwise, if any sample had no data: `.unknown` with the reason of the first gap.
7. Otherwise `.visible`.

A known ridge that hides the target wins over a gap elsewhere: a target known to be hidden is never `unknown`.

Reference values for the tests: the drop at 10 km is 7.848 m with `k = 0`, 6.828 m with `k = 0.13`; at 100 km, 784.8 m and 682.8 m.

## Online tiles

Provider etiquette is code (Swift package rule 4), and VersaTiles is a free demo server whose rate limit answers 429 with no `Retry-After` (CLAUDE.md).

- One `URLSession` per `Terrain`, from a fresh `URLSessionConfiguration` copy, with its own `URLCache` (`diskCacheBytes`, in the app's Caches directory) and `.useProtocolCachePolicy`, so the server's six-hour `Cache-Control` is honoured and a repeated look costs no requests. No header that disables caching, ever.
- `User-Agent`: the app's string plus the package token `Maqs/<version>`; `MaqsTerrain` keeps its own copy of the version and a test checks it against `MaqsCore`'s *(builder's call how)*.
- Requests only for tiles no local archive has, at most four at once, one request per tile however many callers wait for it.
- **429:** no request to the online source for 60 s, doubling on each further 429 up to 15 min, reset by a success. During the cool-down online tiles have no data and results report `.rateLimited`. Never a retry inside a call.
- 404, another status, a transport error or an undecodable body: that tile has no data for this call (`.networkFailure`, or `.noData` for a 404); whether a 404 is remembered for the session is the builder's call.
- **A call fetches at most 128 tiles online** *(designer's call)*, so an app passing thousands of targets or a huge grid cannot burst the provider; tiles beyond the cap are `.missing(.requestCap)`. With decision 10's bands a full look needs about 69.
- Cost: a full 360° look out to 100 km with nothing installed is about 69 tile requests, roughly 11 MB at the fixture's tile sizes, once per six hours per area thanks to the cache. Inside an installed region it makes requests only for the ground beyond the pack's border.
- **Privacy.** Tile requests carry tile coordinates, not the position, but the set of tiles one look requests is a ring centred on the observer. A rough estimate during review puts the observer within a cell of about 0.2 km² (about 500 m across) from the full set, about 1 km from the z12 tiles alone. `docs/architecture.md` and ADR 0015 state this figure, not the size of one tile. Apps with a strict privacy stance use the online opt-out (ADR 0008). Accepted by the owner (decision 11).

## PMTiles reader

Internal, minimal, defensive (Swift package rule 7); mirrors `pipeline/src/maqs/pmtiles_header.py` and `pmtiles_reader.py`:

- 127-byte header, magic `PMTiles` and version 3; every offset and length checked against the file size before a read; tile and internal compression `none` or `gzip` only, anything else a typed error.
- Directories: varint count checked against the bytes available before any allocation (at least four bytes per entry), varints at most ten bytes, entries decoded as the pipeline does, offset run rule included; one level of leaf directories, nested leaves rejected.
- Caps: 16 MiB per directory, 64 MiB per tile, the same as the pipeline; gzip inflation stops at the cap.
- Hilbert tile ids as in `zxy_to_tile_id`.
- File access by memory map or positioned reads *(builder's call)*. A mapped file stays readable if `MaqsCore` removes the pack meanwhile; positioned reads must handle the file disappearing as a typed error.

The reader stays `internal`: nothing outside `MaqsTerrain` needs it yet. Making it public later is additive.

## Errors and logging

- `PMTilesError`: `notPMTiles`, `unsupportedVersion(UInt8)`, `unsupportedCompression`, `truncated`, `corruptDirectory(String)`, `sectionTooLarge`, `nestedLeafDirectory`, `unreadableFile`. Every case's `errorDescription` says what to do ("Remove and reinstall the region").
- `TerrainError`: `invalidConfiguration(String)`, `notTerrain(URL)`, `undecodableTile`, `invalidArea`.
- Local corruption throws: it is a broken install the app should surface (installs are SHA-256-verified, so it should never happen). Online failures are values, `Sample.missing` with a reason, because online is best effort and a route keeps its local values. Cancellation throws `CancellationError`.
- `os.Logger(subsystem: "com.lucavallin.maqs", category: "terrain")`: archive open failures, online outcomes per request (status, bytes, cache hit), cool-down start and end. Tile coordinates and every coordinate are position-derived: `privacy: .private`. Never a full URL with tile coordinates at public level, never tile contents.
- No metrics API: as for `MaqsCore`, a client library's signal is its logs and the reasons in its results; the demo app (sub-project 4) shows them.

## Tests (`Tests/MaqsTerrainTests`, Swift Testing)

No live network; `StubServer` for online tiles; fresh temporary directories; a test clock for the cool-down.

- `PMTilesReaderTests`: every fixture archive opens; tile bytes for chosen `z/x/y` match the pipeline's reader (the golden file carries their SHA-256s); gzip tile compression via the basemap fixture; leaf directories via a small archive a test helper writes *(no committed binaries; the helper lives in the test target)*; truncated header, bad magic, version 2, unknown compression, directory count larger than its bytes, an 11-byte varint, offset or length beyond the file, nested leaf, gzip with each optional header field, bad CRC, inflation over the cap.
- `TileIDTests`: Hilbert ids for known `z/x/y` (from the pipeline) and the out-of-range cases.
- `TerrariumTests`: known RGB to metres, including the extremes.
- `SamplingTests`: the golden file (pipeline sampler values over the `test` region; the fixture has only two z12 tiles, so the golden grid lies inside them) to 1e-6 m; edge clamping; `.noData` outside coverage, at the poles and for non-finite input; the hd archive preferred where it covers; no online request for a point a local archive covers; `grid` zoom chosen from the cell spacing.
- `ProfileTests`: great-circle points against known values; the drop values above; `EarthModel.none`; band switching.
- `VisibilityTests`, over a synthetic in-memory tile source (an internal protocol the tests implement, not a mock of anything we do not own): flat ground visible; a ridge hides; a ridge within the margin does not; the target's own slope within `targetClearance` ignored; true summit height makes a peak visible that the ground value hides; a gap gives `unknown`, but a known ridge plus a gap gives `hidden`; `outOfRange`; observer and target unknown; results in input order.
- `OnlineTests`: no request without a source; User-Agent on every request and no cache-disabling header; 429 starts the cool-down and samples report `.rateLimited`, the clock ends it, a success resets the doubling; 404 is `.noData` and garbage `.networkFailure`; at most four in flight; one request for a tile many callers want; the 128-tile cap gives `.requestCap`.
- `CacheTests`: the byte bound holds under a sweep; least recently used tiles go first.
- `ConfigurationTests`: `OnlineTerrainSource` rejects each invalid template, format, size and zoom; blank User-Agent with an online source is rejected; `notTerrain` for the basemap fixture.

**Golden file.** `scripts/update-fixtures.sh` gains one step: a short pipeline script *(where it lives is the builder's call; `uv run python` against `maqs.osm.terrain_sampler` is enough)* writes `Fixtures/test/terrain-golden.json` with the elevation at a grid of coordinates inside the `test` bbox and the SHA-256 of a few tiles, so the Swift and Python implementations are tested against each other and regenerated together. A few KB, under the 8 MB cap.

## Documentation

- **ADR 0015 — `MaqsTerrain`**: the decisions above, the online source type (closing ADR 0014's open question for terrain), the sampling rule shared with the pipeline, the zoom bands and their tile numbers, the visibility semantics, cache bounds, the 429 policy and request cap, the verified facts with dates, and the ADR 0008 pixel-size correction.
- `docs/data-format.md`: § Elevation sampling as the one normative text; the trails section links to it.
- `docs/architecture.md` § Swift package: `MaqsTerrain` available; its sources, online path and privacy note (what a tile request reveals at each zoom).
- `README.md`: the product, a short example including the `TileSource` → `OnlineTerrainSource` mapping and the `onlineSources == nil` case.
- `CLAUDE.md` §1: the scheme is now `Maqs-Package`; traps found while building (gzip header handling, ImageIO pixel layout, and anything else).

## Out of scope

The live-sweep mode; an `ascentDescent` helper (decision 12); a public PMTiles reader; MapLibre, hillshade or anything visual (sub-project 4); places queries (sub-project 3); downloading or installing packs (`MaqsCore`); terrain encodings other than terrarium; tile formats other than WebP and PNG for elevation; remote PMTiles range reads.

## Risks

- ImageIO's WebP decoder on iOS may lay pixels out differently from macOS; the decoder handles both layouts and the simulator leg tests the fixture tiles.
- The fixtures have no leaf directories and real region archives do; the test-written archive covers the code path, the pipeline's reader (which reads real leaf directories in every region build) is the reference.
- VersaTiles' rate limit is unpublished; the cool-down and the cap are guesses at a safe pace, recorded as such in the ADR.
- 64 MiB of decoded tiles by default is noticeable on older iPhones; it is a parameter, and the plan measures a full look's peak memory.
- Speed: the target is a full look (about 200 targets out to 100 km, local data) in under 2 s *(designer's call)*. A test logs the time on macOS and the plan measures it once on the simulator; it is not a CI assertion, since runner timings vary. Decoding runs in parallel only if the measurement misses the target.
