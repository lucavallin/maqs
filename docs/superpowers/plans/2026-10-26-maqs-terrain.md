# `MaqsTerrain` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `MaqsTerrain` product: a defensive PMTiles v3 reader, terrarium decoding through ImageIO, elevation sampling identical to the pipeline's, great-circle profiles with curvature and refraction, a line-of-sight visibility query, and a rate-limit-aware online tile path with bounded caches.

**Architecture:** A public `actor Terrain` owns an ordered list of internal `TileProvider`s (local PMTiles archives, finest first, then at most one online provider) and a byte-bounded LRU of decoded tiles. Every call does the same three steps: *locate* each coordinate on a provider tile at the zoom the call needs, *load* the distinct tiles (cache, then provider, within a per-call online budget of 128), then *sample* synchronously. Missing data is a value with a reason (`ElevationSample.missing`), never `nil`; local corruption throws.

**Tech Stack:** Swift 6.2 tools, Swift 6 language mode, iOS 18 / macOS 15; Foundation (`URLSession`, `URLCache`), ImageIO + CoreGraphics (WebP/PNG decode), Compression (raw DEFLATE), CoreLocation (`CLLocationCoordinate2D` only), Synchronization, `os.Logger`; Swift Testing. Pipeline side: Python via `uv`, pytest, ruff.

**Spec:** `docs/superpowers/specs/2026-10-25-maqs-terrain-design.md`

## Global Constraints

- `Package.swift`: tools 6.2, `platforms: [.iOS(.v18), .macOS(.v15)]`, `swiftLanguageModes: [.v6]`, every target `swiftSettings: [.treatAllWarnings(as: .error)]`, no `unsafeFlags`. `MaqsTerrain` has **no dependency**.
- `MaqsTerrain` imports only Foundation, ImageIO, CoreGraphics, Compression, CoreLocation, os, Synchronization. Never `MaqsCore`, `MapLibre` or `SQLite3`.
- Every `public` symbol has a DocC comment; everything else `internal`. No `try!`; no force unwrap outside tests; no `fatalError` on a recoverable path; no `@unchecked Sendable` without a written justification in a comment.
- Errors: `PMTilesError` and `TerrainError`, both `LocalizedError` with descriptions that say what to do. Online failures are `ElevationSample.missing(reason)` values, never thrown and never `nil`. Cancellation throws `CancellationError`.
- Logging: `Logger(subsystem: "com.lucavallin.maqs", category: "terrain")`. Coordinates, tile coordinates and tile URLs are logged only with `privacy: .private`; never tile contents.
- No provider URL in `Sources/`. Tests use `https://tiles.example.org/{z}/{x}/{y}`.
- Online requests: `User-Agent: <app string> Maqs/0.1.0`, `cachePolicy: .useProtocolCachePolicy`, never a `Cache-Control` or `Pragma` request header.
- Defaults, verbatim from the spec: `memoryCacheBytes = 64 << 20`; `diskCacheBytes = 64 << 20`; `EarthModel(radius: 6_371_008.8, refraction: 0.13)`; `ZoomBands.standard = [(10_000, 12), (30_000, 11), (40_000, 10), (.infinity, 9)]`; `maxDistance = 100_000`; `margin = 10`; `targetClearance = 150`; `ObserverHeight.aboveGround(1.7)`; online: at most **128** tile fetches per call, **4** concurrent, 429 cool-down **60 s** doubling to **900 s**, reset by a success.
- PMTiles caps (same as the pipeline): directory 16 MiB, tile 64 MiB, metadata 8 MiB, varint at most 10 bytes.
- Input bounds (plan refinement, `TerrainError.invalidInput`): grid `columns` and `rows` in `1...1024`; profile `step` ≥ 1 m and at most 100,000 points; at most 5,000 visibility targets; non-finite endpoints or observer rejected.
- Fixtures: only `scripts/update-fixtures.sh` and `scripts/update-terrain-golden.sh` write `Tests/MaqsTestSupport/Fixtures/`; total under 8 MB.
- `swift test --filter` takes the suite name (`TileIDTests`), never `MaqsTerrainTests/TileIDTests`.
- Swift Testing runs suites in parallel: one `StubServer` and one `TemporaryDirectory` per test; nothing global.
- Commits: `type(scope): summary` with a body when a decision was made; no attribution trailer of any kind. Never push; the controller pushes.

## Review Focus

1. **A target at, or within a metre of, the observer** (the user standing on the summit) gives finite values: `.visible(distance:, bearing: 0, elevationAngle: 0)`, never NaN. Pinned in Task 9 ("a target at the observer is visible with finite values").
2. **Degenerate or huge requests** (grid 0 or 100,000 columns, profile step 0.1 m or NaN endpoints, 10,000 targets, NaN observer) are `TerrainError.invalidInput` before any tile is touched; a NaN target is that target's `.unknown(at: .target, reason: .noData, distance: 0)`. Pinned in Tasks 7, 8 and 9.
3. **Longitudes at or across ±180°**: a destination across the antimeridian is normalised to [−180, 180), and `WebMercator.position` never yields an x outside `0..<2^z`. Pinned in Tasks 4 and 8.
4. **An archive removed or truncated while a `Terrain` holds it** (`MaqsCore` removes or updates a pack mid-look): a removed file still reads (the descriptor keeps it alive); a truncated one throws `PMTilesError.truncated`, never crashes. Pinned in Task 3.
5. **A caller cancelled while waiting on a shared online fetch** throws `CancellationError`, does not cancel the fetch for other waiters, and leaves no stuck in-flight entry: a later call for the same tile succeeds. Pinned in Task 6.

## Rollback, observability, cost

- **Rollback:** additive. A new product nothing depends on yet, a new fixture file, one pipeline module and a CI guard; revert the commits. No data format, schema or release changes.
- **Observability:** `terrain` log category (archive open failures, online status per request, cool-down start/end); every degraded answer carries its `MissingReason`. The demo app (sub-project 4) shows them. No alert applies to a client library.
- **Cost:** no pipeline or release cost (the golden step reads one local file in seconds). `swift.yml` runs a few hundred more fast tests. Per app: a full online look with nothing installed is about 69 tile requests (~11 MB) at most once per six hours per area; zero requests inside an installed region.

## File structure

```
Package.swift                                   + product/target MaqsTerrain, test target MaqsTerrainTests; MaqsTestSupport drops MaqsCore
.github/workflows/swift.yml                     + guard: MaqsTerrain and MaqsCore carry the same version string
scripts/update-terrain-golden.sh                new: writes Fixtures/test/terrain-golden.json from the committed terrain fixture
scripts/update-fixtures.sh                      calls update-terrain-golden.sh after copying
pipeline/src/maqs/terrain_golden.py             new: golden values from the pipeline's reader and sampler
pipeline/tests/test_terrain_golden.py           new
Tests/MaqsTestSupport/Fixtures/test/terrain-golden.json   generated

Sources/MaqsTerrain/
  Logging.swift                 the one Logger
  TerrainVersion.swift          enum TerrainVersion { static let string = "0.1.0" }
  PMTiles/PMTilesError.swift    public enum PMTilesError
  PMTiles/TileID.swift          Hilbert tile ids
  PMTiles/Directory.swift       varints, directory decode, entry lookup
  PMTiles/Gzip.swift            RFC 1952 member → raw DEFLATE via Compression, CRC-32, output cap
  PMTiles/PMTilesHeader.swift   127-byte header
  PMTiles/PMTilesArchive.swift  descriptor, positioned reads, metadata, leaf cache, tile(z:x:y:)
  Tiles/TileKey.swift           struct TileKey { z, x, y }
  Tiles/WebMercator.swift       lon/lat → tile + pixel; pixel size in metres
  Tiles/Terrarium.swift         RGB → metres
  Tiles/ElevationTile.swift     decoded tile, bilinear sample
  Tiles/TerrariumDecoder.swift  ImageIO → ElevationTile
  Tiles/TileCache.swift         byte-bounded LRU
  Providers/TileProvider.swift  protocol TileProvider, enum TileLoad
  Providers/LocalTileProvider.swift
  Providers/OnlineTileProvider.swift
  Providers/CoolDown.swift
  Providers/AsyncLimiter.swift
  Geodesy/Geodesy.swift         haversine, bearing, destination, intermediate point
  Terrain.swift                 public actor Terrain (locate / load / sample core + public calls)
  Terrain+Visibility.swift      the visibility query
  Public/…                      one file per public value type: ElevationSample.swift (+MissingReason), TerrainError.swift,
                                OnlineTerrainSource.swift, TerrainConfiguration.swift, TerrainArea.swift, ElevationGrid.swift,
                                EarthModel.swift, ZoomBands.swift, ProfileOptions.swift, ElevationProfile.swift,
                                Observer.swift, SightTarget.swift, VisibilityOptions.swift, Visibility.swift

Tests/MaqsTerrainTests/
  Support/Golden.swift          Decodable model of terrain-golden.json
  Support/PMTilesWriter.swift   writes small archives (leaf directories, corrupt variants)
  Support/GzipMember.swift      builds gzip members with chosen header fields
  Support/SyntheticTerrain.swift TileProvider from an elevation closure, with gaps and a load log
  <Type>Tests.swift             one suite per file, named in each task
```

---

### Task 1: Golden values from the pipeline

The Swift reader and sampler are tested against the Python ones through one generated file.

**Files:**
- Create: `pipeline/src/maqs/terrain_golden.py`, `pipeline/tests/test_terrain_golden.py`, `scripts/update-terrain-golden.sh`
- Modify: `scripts/update-fixtures.sh` (call the new script after the `cp` lines, before the size check)
- Generate: `Tests/MaqsTestSupport/Fixtures/test/terrain-golden.json`

**Interfaces:**
- Produces `terrain-golden.json`, read by Tasks 2–5 and 7:

```json
{
  "golden_version": 1,
  "archive": "test-terrain.v1.pmtiles",
  "zoom": 12,
  "tile_ids": [{"z": 0, "x": 0, "y": 0, "id": 0}, ...],
  "tiles": [{"z": 12, "x": 2187, "y": 1455, "sha256": "<hex of the decompressed tile bytes>"}, ...],
  "points": [{"lon": 12.21, "lat": 46.08, "elevation": 334.0}, {"lon": ..., "lat": ..., "elevation": null}, ...]
}
```

- `build_golden(archive: Path) -> dict[str, object]` and `main(argv: list[str] | None = None) -> int` (`python -m maqs.terrain_golden ARCHIVE OUT`).

- [ ] **Step 1: Write the failing pytest** `test_golden_matches_the_sampler`: build a one-tile z12 archive with `tests.helpers.write_pmtiles` and `tests.test_terrain_sampler.terrarium_tile(lambda px, py: px + py / 4)` at `12/2187/1455`; `golden = build_golden(path)`; assert `golden["golden_version"] == 1`, `golden["zoom"] == 12`, every point's `elevation` equals `TerrainSampler(path).elevation(lon, lat)` (both `None` together), every `tiles` entry's `sha256` equals `hashlib.sha256(PMTilesArchive(path).tile(z, x, y)).hexdigest()`, and `tile_ids` contains exactly the seven pairs below with `id == zxy_to_tile_id(z, x, y)`. A second test, `test_main_writes_sorted_json`, runs `main([str(path), str(out)])`, gets 0, and the file parses back to the same dict.
- [ ] **Step 2: Run** `cd pipeline && uv run pytest tests/test_terrain_golden.py -q`. Expected: FAIL, `ModuleNotFoundError: maqs.terrain_golden`.
- [ ] **Step 3: Implement `build_golden`.** `points`: a 25 × 25 grid over the header bbox, corners included, row-major from the north-west, `elevation` from `TerrainSampler.elevation`. `tiles`: for every zoom `min_zoom...max_zoom`, every `x, y` between the tiles of the bbox corners (`lonlat_to_pixel(..., tile_size=1)`), each tile the archive has. `tile_ids`: `(0,0,0)`, `(1,0,0)`, `(1,1,1)`, `(5,17,11)`, `(12,2187,1455)`, `(12,4095,4095)`, `(26,67108863,0)`. `main` writes `json.dumps(..., sort_keys=True, indent=1)` plus a newline. Type hints, `pathlib`, no `shell=True`.
- [ ] **Step 4: Run** the pytest again, then `uv run ruff check . && uv run ruff format --check .`. Expected: PASS, no lint findings.
- [ ] **Step 5: Write `scripts/update-terrain-golden.sh`** (`set -euo pipefail`, repo-root-relative like `update-fixtures.sh`): `(cd pipeline && uv run python -m maqs.terrain_golden <fixtures>/test/test-terrain.v1.pmtiles <fixtures>/test/terrain-golden.json)`. Call it from `update-fixtures.sh` after the copies. Run `scripts/update-terrain-golden.sh`. Expected: the JSON exists, `git status` shows only it and the scripts/pipeline files, `du -sk Tests/MaqsTestSupport/Fixtures` stays under 8192, and the file holds `"id": 19825135` for `12/2187/1455` and `"id": 6004799503160660` for `26/67108863/0`.
- [ ] **Step 6: Commit** `test(fixtures): golden terrain values from the pipeline's reader and sampler`.

### Task 2: Target, tile ids and directories

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MaqsTerrain/{Logging,TerrainVersion}.swift`, `Sources/MaqsTerrain/PMTiles/{PMTilesError,TileID,Directory}.swift`, `Tests/MaqsTerrainTests/Support/Golden.swift`, `Tests/MaqsTerrainTests/{TileIDTests,DirectoryTests}.swift`

**Interfaces:**
- Produces:

```swift
public enum PMTilesError: Error, Equatable, LocalizedError {
    case notPMTiles, unsupportedVersion(UInt8), unsupportedCompression(UInt8), truncated
    case corruptDirectory(String), corruptCompressedData(String)   // the second is a plan refinement: bad gzip
    case sectionTooLarge, nestedLeafDirectory, unreadableFile
}
enum TileID { static func id(z: Int, x: Int, y: Int) -> UInt64? }      // nil outside z 0...31, x/y 0..<2^z
struct DirectoryEntry: Equatable, Sendable { let tileID: UInt64; let offset: UInt64; let length: UInt64; let runLength: UInt64 }
enum Directory {
    static func decode(_ data: Data) throws(PMTilesError) -> [DirectoryEntry]
    static func find(_ entries: [DirectoryEntry], tileID: UInt64) -> DirectoryEntry?   // runLength 0 = leaf pointer
}
struct Golden: Decodable { … }   // test target; snake_case keys; `static func load() throws -> Golden` via Fixtures.url("test/terrain-golden.json")
```

- [ ] **Step 1: Package.** Add `.library(name: "MaqsTerrain", targets: ["MaqsTerrain"])`, `.target(name: "MaqsTerrain", swiftSettings: warningsAsErrors)`, `.testTarget(name: "MaqsTerrainTests", dependencies: ["MaqsTerrain", "MaqsTestSupport"], swiftSettings: warningsAsErrors)`. Remove `"MaqsCore"` from `MaqsTestSupport`'s dependencies (its sources import only Foundation, Synchronization, CryptoKit); `swift build` and `swift test --filter ManifestTests` must still pass. `Logging.swift` and `TerrainVersion.swift` as in the file structure.
- [ ] **Step 2: Write failing tests.** `TileIDTests`: "ids match the pipeline" (every golden `tile_ids` entry); "out-of-range tiles have no id" (`z: 32`, `z: -1`, `x: 1 << 12` at z12, `y: -1`). `DirectoryTests`, with hand-encoded bytes (varint count, id deltas, run lengths, lengths, offsets+1): "decodes two entries with the offset run rule" (second offset field 0 → `offset[0] + length[0]`); "a count larger than its bytes is corrupt" (count 1,000 in 10 bytes); "an 11-byte varint is corrupt"; "a truncated varint is corrupt"; "a first offset field of zero is corrupt"; "an id delta that overflows UInt64 is corrupt"; "find returns a leaf pointer for ids after it"; "find returns nil past a run". Each corrupt case `#expect(throws: PMTilesError.corruptDirectory…)` (match the case, not the message).
- [ ] **Step 3: Run** `swift test --filter TileIDTests` and `--filter DirectoryTests`. Expected: FAIL to compile (types missing).
- [ ] **Step 4: Implement** `TileID.id` as `pipeline/src/maqs/pmtiles_reader.py:zxy_to_tile_id` in `UInt64`; `Directory.decode` as `read_directory` with the count check before allocating and overflow-checked arithmetic; `find` as `find_entry` (binary search). `errorDescription` for every case, e.g. "This map file is damaged. Remove the region and install it again." for `corruptDirectory`.
- [ ] **Step 5: Run** both suites, then `swift build`. Expected: PASS, no warnings.
- [ ] **Step 6: Commit** `feat(terrain): MaqsTerrain target, Hilbert tile ids and PMTiles directories`.

### Task 3: Gzip, header and archive

**Files:**
- Create: `Sources/MaqsTerrain/PMTiles/{Gzip,PMTilesHeader,PMTilesArchive}.swift`, `Tests/MaqsTerrainTests/Support/{GzipMember,PMTilesWriter}.swift`, `Tests/MaqsTerrainTests/{GzipTests,PMTilesArchiveTests}.swift`

**Interfaces:**
- Consumes: `Directory`, `TileID`, `PMTilesError` (Task 2).
- Produces:

```swift
enum Gzip {
    /// One RFC 1952 member; bytes after its trailer are ignored, as zlib does for the pipeline.
    static func inflate(_ data: Data, limit: Int) throws(PMTilesError) -> Data
}
enum CRC32 { static func checksum(_ data: Data) -> UInt32 }
enum PMTilesCompression: UInt8, Sendable { case none = 1, gzip = 2 }
struct PMTilesHeader: Sendable, Equatable {
    var rootOffset, rootLength, metadataOffset, metadataLength, leafOffset, leafLength, tileDataOffset, tileDataLength: UInt64
    var addressedTiles: UInt64; var clustered: Bool
    var internalCompression, tileCompression: PMTilesCompression
    var tileType: UInt8; var minZoom, maxZoom: Int
    var bounds: (west: Double, south: Double, east: Double, north: Double)   // from the e7 fields; Equatable by hand
    static func parse(_ bytes: Data, fileSize: UInt64) throws(PMTilesError) -> PMTilesHeader
}
final class PMTilesArchive: Sendable {
    init(url: URL) throws(PMTilesError)     // header, root directory, metadata parsed and checked
    let url: URL; let header: PMTilesHeader
    let tileSchema: String?; let tileSize: Int?          // metadata "tile_schema", "tile_size" when present
    func contains(z: Int, x: Int, y: Int) throws(PMTilesError) -> Bool
    func tile(z: Int, x: Int, y: Int) throws(PMTilesError) -> Data?   // decompressed; nil when absent
}
// tests: GzipMember.make(_ payload: Data, extra: Data? = nil, name: String? = nil, comment: String? = nil, headerCRC: Bool = false) -> Data
// tests: PMTilesWriter.write(tiles: [(z: Int, x: Int, y: Int, data: Data)], to: URL, leafEntries: Int? = nil,
//        tileType: UInt8 = 4, metadata: [String: String] = ["tile_schema": "dem/terrarium"], minZoom/maxZoom inferred) throws
```

- [ ] **Step 1: Write failing `GzipTests`:** "CRC-32 of 123456789 is CBF43926"; "inflates a plain member"; one test each for a member with `FEXTRA`, `FNAME`, `FCOMMENT` and a valid `FHCRC`; "rejects a bad magic", "rejects a method other than deflate", "rejects reserved flag bits", "rejects a truncated header", "rejects a bad CRC", "rejects a wrong length", "rejects a truncated body" (all `corruptCompressedData`); "stops at the limit" (`sectionTooLarge` for a 1 MiB payload with `limit: 1000`); "inflates the terrain fixture's root directory" (read `rootOffset/rootLength` bytes of `test/test-terrain.v1.pmtiles`, inflate with 16 MiB, `Directory.decode` gives 14 entries).
- [ ] **Step 2: Write failing `PMTilesArchiveTests`:** "every fixture archive opens" (all six `.pmtiles` in `Fixtures/test/`); "the terrain header is what the pipeline reads" (tile type 4, zoom 0...12, internal gzip, tile compression none, clustered, 14 addressed tiles, `tileSchema == "dem/terrarium"`, `tileSize == 512`); "terrain tiles match the pipeline's bytes" (every golden `tiles` entry: SHA-256 via `MaqsTestSupport`'s helper); "basemap tiles inflate" (`z0/0/0` non-empty after gzip); "an absent tile is nil"; "a tile behind a leaf directory reads" (`PMTilesWriter` with `leafEntries: 2` and five tiles); "a nested leaf directory is rejected"; corruption, each on a copy in a `TemporaryDirectory`: header shorter than 127 bytes (`truncated`), bad magic (`notPMTiles`), version byte 2 (`unsupportedVersion(2)`), internal compression byte 3 (`unsupportedCompression(3)`), root directory past the end (`truncated`), tile entry past the tile data (`corruptDirectory`), leaf pointer past the leaf section (`corruptDirectory`), tile length over 64 MiB (`sectionTooLarge`), metadata over 8 MiB (`sectionTooLarge`); "a missing file is unreadableFile"; **Review Focus 4:** "a removed file still reads" (open, delete, `tile` returns the bytes) and "a file truncated after opening throws truncated".
- [ ] **Step 3: Run** `swift test --filter GzipTests` and `--filter PMTilesArchiveTests`. Expected: FAIL.
- [ ] **Step 4: Implement.** `Gzip`: parse the header fields per RFC 1952, inflate the body with `compression_stream` (`COMPRESSION_ZLIB`, decode), refusing output past `limit`, then check the trailer's CRC-32 and ISIZE. `PMTilesHeader.parse`: the v3 layout (7-byte magic, version, eleven little-endian `UInt64`s, clustered, compressions, tile type, zooms, four `Int32` e7 bounds, centre); every section's `offset + length` checked against `fileSize` without overflow. `PMTilesArchive`: one descriptor opened with `O_RDONLY | O_CLOEXEC` and held until `deinit` (a removed file stays readable), `pread` for every read (a short read is `truncated`), the 16 MiB / 64 MiB / 8 MiB caps, metadata JSON decoded for `tile_schema` and `tile_size` only, decoded leaf directories cached in a small LRU (16 leaves, the builder may tune it, never unbounded). Store the descriptor as an `Int32` so the class is `Sendable` without `@unchecked`.
- [ ] **Step 5: Run** both suites and `swift build`. Expected: PASS, no warnings.
- [ ] **Step 6: Commit** `feat(terrain): gzip members, PMTiles header and a bounds-checked archive reader`.

### Task 4: Web Mercator, terrarium and decoding

**Files:**
- Create: `Sources/MaqsTerrain/Tiles/{TileKey,WebMercator,Terrarium,ElevationTile,TerrariumDecoder}.swift`, `Sources/MaqsTerrain/Public/TerrainError.swift`, `Tests/MaqsTerrainTests/{WebMercatorTests,TerrariumTests,ElevationTileTests,TerrariumDecoderTests}.swift`

**Interfaces:**
- Consumes: `PMTilesArchive` (Task 3) for the fixture tile in tests.
- Produces:

```swift
struct TileKey: Hashable, Sendable { let z: Int; let x: Int; let y: Int }
enum WebMercator {
    /// nil for non-finite input or |lat| >= 85.05; longitude normalised to [-180, 180) first.
    static func position(longitude: Double, latitude: Double, zoom: Int, tileSize: Int) -> (key: TileKey, pixelX: Double, pixelY: Double)?
    static func pixelSize(zoom: Int, tileSize: Int, latitude: Double) -> Double   // cos(lat) * 2π * 6_378_137 / (tileSize * 2^zoom)
}
enum Terrarium { static func elevation(red: UInt8, green: UInt8, blue: UInt8) -> Double }
final class ElevationTile: Sendable {
    let size: Int
    init(size: Int, elevations: [Float]) throws(TerrainError)    // count must be size * size
    func elevation(pixelX: Double, pixelY: Double) -> Double      // the pipeline's bilinear rule
    var byteCount: Int { get }
}
enum TerrariumDecoder { static func decode(_ data: Data, expectedSize: Int?) throws(TerrainError) -> ElevationTile }
public enum TerrainError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String), notTerrain(URL), undecodableTile, invalidArea
    case invalidInput(String)          // plan refinement: the input bounds of Global Constraints
}
```

- [ ] **Step 1: Write failing tests.** `WebMercatorTests`: "the test bbox centre is tile 12/2187/1455" (`12.25, 46.105`, 512 px; pixel inside `0..<512`); "pixel size at z12 and 46.1° is about 13.3 m" (`13.25...13.35`); "no position at the poles or for NaN"; **Review Focus 3:** "longitude 180 wraps to tile x 0" and "longitude -180 is tile x 0", x always in `0..<1 << z`. `TerrariumTests`: `(128,0,0)` → 0; `(131,232,128)` → 1000.5; `(0,0,0)` → −32768; `(255,255,255)` → 32767.99609375. `ElevationTileTests`: exact values at pixel centres; the midpoint of four centres is their mean; clamped below 0.5 and above `size - 0.5`; a wrong element count throws `invalidInput`. `TerrariumDecoderTests`: "the fixture tile decodes like Pillow" (tile 12/2187/1455 from the archive, 512 px; at pixel centres `(0,0)` 334.0, `(100,200)` 438.5, `(255,255)` 907.0, `(511,511)` 1468.75, `(300,17)` 584.0 — the RGB values Pillow and ImageIO both returned on 2026-10-25); "an 8-bit PNG decodes through the provider bytes" and "a 16-bit PNG decodes through the redraw to the same values" (both written in the test with `CGImageDestination` from known RGB); "a non-square image is undecodable"; "a size other than expected is undecodable"; "garbage is undecodable".
- [ ] **Step 2: Run** the four suites. Expected: FAIL.
- [ ] **Step 3: Implement.** `position` mirrors `lonlat_to_pixel` (floor of the fractional tile, pixel = fraction × size). `elevation(pixelX:pixelY:)` mirrors `TerrainSampler.elevation` after the tile lookup: `px - 0.5` clamped to `0...size-1`, `x1 = min(x0 + 1, size - 1)`, interpolate in `Double`. Store `Float` (terrarium values are exact in `Float`). `TerrariumDecoder`: `CGImageSourceCreateWithData`, image 0; read the provider bytes when the image is 8 bits per component, 24 or 32 bits per pixel, RGB order, alpha `none`, `noneSkipLast`, `last` or `premultipliedLast`; otherwise draw into an RGBA8 `CGContext` **in the image's own colour space** when its model is RGB, else `undecodableTile`.
- [ ] **Step 4: Run** the four suites. Expected: PASS.
- [ ] **Step 5: Commit** `feat(terrain): web mercator positions, terrarium decoding through ImageIO, bilinear tiles`.

### Task 5: Providers, cache and the sampling core

**Files:**
- Create: `Sources/MaqsTerrain/Providers/{TileProvider,LocalTileProvider}.swift`, `Sources/MaqsTerrain/Tiles/TileCache.swift`, `Sources/MaqsTerrain/Public/ElevationSample.swift`, `Sources/MaqsTerrain/Terrain.swift`, `Tests/MaqsTerrainTests/Support/SyntheticTerrain.swift`, `Tests/MaqsTerrainTests/{TileCacheTests,LocalTileProviderTests,SamplingTests}.swift`

**Interfaces:**
- Consumes: Tasks 3–4.
- Produces:

```swift
public enum MissingReason: Sendable, Equatable { case noData, rateLimited, networkFailure, requestCap }
public enum ElevationSample: Sendable, Equatable { case elevation(Double), missing(MissingReason) }
enum TileLoad: Sendable { case tile(ElevationTile), missing(MissingReason) }
protocol TileProvider: Sendable {
    var zoomRange: ClosedRange<Int> { get }
    var tileSize: Int { get }                 // the size positions are computed with
    var isOnline: Bool { get }
    func covers(_ key: TileKey) throws -> Bool          // local: directory lookup; online: zoom in range
    func load(_ key: TileKey) async throws -> TileLoad
}
final class LocalTileProvider: TileProvider {   // Sendable: immutable over a Sendable archive
    init(url: URL) throws        // PMTilesError, or TerrainError.notTerrain unless tile type 2/4 and tile_schema absent or "dem/terrarium"
}
final class TileCache {          // actor-owned by Terrain, not Sendable
    init(byteLimit: Int)
    func tile(for key: SourceTile) -> ElevationTile?
    func insert(_ tile: ElevationTile, for key: SourceTile)   // evicts least recently used until within the limit; a tile larger than the limit is not kept
    var byteCount: Int { get }
}
struct SourceTile: Hashable, Sendable { let provider: Int; let key: TileKey }
struct SamplePoint: Sendable { let tile: SourceTile?; let pixelX: Double; let pixelY: Double }
public actor Terrain {
    init(providers: [any TileProvider], memoryCacheBytes: Int)        // internal; sorts locals by zoomRange.upperBound descending, online last
    func locate(_ coordinate: CLLocationCoordinate2D, zoomLimit: Int) throws -> SamplePoint
    func load(_ tiles: Set<SourceTile>, budget: inout Int) async throws -> [SourceTile: TileLoad]
    func samples(at coordinates: [CLLocationCoordinate2D], zoomLimits: [Int]) async throws -> [ElevationSample]
    var cachedBytes: Int { get }   // tests only
}
// tests: SyntheticTerrain(tileSize: 256, zoomRange: 0...14, isOnline: false, elevation: @Sendable (lon, lat) -> Double?,
//        gap: @Sendable (TileKey) -> Bool = { _ in false }); `loads: [TileKey]` log; tiles filled at pixel centres
```

`locate` rule: for each provider in order, `z = min(zoomLimit, provider.zoomRange.upperBound)`; skip it when `z < provider.zoomRange.lowerBound`; position at `z` with the provider's tile size; the first provider whose `covers` is true wins. None: `SamplePoint(tile: nil, …)`, sampled as `.missing(.noData)`. `load`: cache first; then the provider; an online provider's fetch first takes one from `budget` and, at zero, is `.missing(.requestCap)` without a call. Local `load` errors propagate.

- [ ] **Step 1: Write failing tests.** `TileCacheTests`: "the byte bound holds under a sweep" (insert 100 one-MiB tiles into a 10 MiB cache, `byteCount <= 10 << 20` after each); "least recently used goes first" (touch A, insert until one eviction, B gone, A kept); "a tile larger than the limit is not kept". `LocalTileProviderTests`: "the terrain fixture is a provider" (zoom 0...12, size 512); "the basemap fixture is not terrain" (`TerrainError.notTerrain`); "an archive without tile_schema is accepted". `SamplingTests`: "samples match the pipeline" (every golden point through `samples(at:zoomLimits:)` with limit `Int.max`: value within 1e-6, `null` ↔ `.missing(.noData)`); "a terrain-hd archive is preferred where it covers" (a `PMTilesWriter` z13 archive, tile type 2, holding one constant-2000 m PNG tile written with `CGImageDestination` (RGB 135, 208, 0), plus the fixture: points in that tile give 2000, others the fixture's value); "no online load for a point a local archive covers" (a `SyntheticTerrain(isOnline: true)` after the fixture: its `loads` stays empty for golden points); "online fills what local lacks"; "a 256 px provider samples correctly" (`SyntheticTerrain` with `elevation = lat * 1000`: the sample equals the bilinear value of its centres within 1e-6); "the online budget stops at 128" (129 distinct z12 tiles from an online `SyntheticTerrain`: 128 loads, one `.missing(.requestCap)`).
- [ ] **Step 2: Run** the three suites. Expected: FAIL.
- [ ] **Step 3: Implement** the types above. `samples(at:zoomLimits:)` = locate each, load the distinct tiles once, sample each point synchronously. Decoding several tiles in parallel inside `load` is the builder's call.
- [ ] **Step 4: Run** the three suites and `swift build`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(terrain): tile providers, a byte-bounded tile cache and sampling identical to the pipeline`.

### Task 6: Online tiles

**Files:**
- Create: `Sources/MaqsTerrain/Providers/{OnlineTileProvider,CoolDown,AsyncLimiter}.swift`, `Sources/MaqsTerrain/Public/OnlineTerrainSource.swift`, `Tests/MaqsTerrainTests/{OnlineTerrainSourceTests,CoolDownTests,AsyncLimiterTests,OnlineTileProviderTests}.swift`
- Modify: `.github/workflows/swift.yml` (guards job)

**Interfaces:**
- Consumes: `TileProvider`, `TileLoad`, `TerrariumDecoder`, `Terrain.init(providers:memoryCacheBytes:)` (Tasks 4–5).
- Produces:

```swift
public struct OnlineTerrainSource: Sendable, Equatable {
    public init(tiles: String, format: String, tileSize: Int, minZoom: Int, maxZoom: Int) throws(TerrainError)
    public let tiles: String; public let format: String; public let tileSize: Int; public let minZoom: Int; public let maxZoom: Int
    func url(for key: TileKey) -> URL?
}
struct CoolDown: Sendable {      // 60 s, doubling per further 429, capped at 900 s, reset by success
    mutating func rateLimited(at now: ContinuousClock.Instant)
    mutating func succeeded()
    func isActive(at now: ContinuousClock.Instant) -> Bool
}
actor AsyncLimiter { init(limit: Int); func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T }
actor OnlineTileProvider: TileProvider {
    init(source: OnlineTerrainSource, userAgent: String, sessionConfiguration: URLSessionConfiguration,
         cacheDirectory: URL?, diskCacheBytes: Int, now: @escaping @Sendable () -> ContinuousClock.Instant)
}
```

Behaviour of `load`: during a cool-down, `.missing(.rateLimited)` with no request; otherwise one request per key (concurrent callers share an in-flight task, removed when it ends), at most 4 running through the limiter. 200 → decode with `expectedSize: source.tileSize` (failure `.networkFailure`), success resets the cool-down; 404 → `.noData`; 429 → cool-down, `.rateLimited`; any other status or transport error → `.networkFailure`; a cancelled caller throws `CancellationError` without cancelling the shared fetch. The session is built from a **copy** of `sessionConfiguration`, keeps its `httpAdditionalHeaders`, sets `urlCache = URLCache(memoryCapacity: 0, diskCapacity: diskCacheBytes, directory: cacheDirectory)` when a directory is given, and `requestCachePolicy = .useProtocolCachePolicy`. Each request sets only `User-Agent` (the full string is passed in). Logs status and byte count per request, cool-down start and end; the key with `privacy: .private`.

- [ ] **Step 1: Write failing tests.** `OnlineTerrainSourceTests`: accepts `https://tiles.example.org/{z}/{x}/{y}`, `webp`, 512, 0, 12; rejects one at a time: `http://` template, no host, `user:pw@` credentials, each of `{z}`, `{x}`, `{y}` missing, format `jpg`, tile size 300, `minZoom -1`, `minZoom > maxZoom`, `maxZoom 23` (`invalidConfiguration`); `url(for:)` substitutes all three. `CoolDownTests`: inactive at start; active for 60 s after one 429, inactive at +61 s; a second 429 lasts 120 s; never longer than 900 s; `succeeded()` resets to 60. `AsyncLimiterTests`: "never more than four at once" (twelve bodies that each record entry and wait on a continuation the test releases; observed maximum 4; all finish); "a waiter cancelled before its turn throws CancellationError". `OnlineTileProviderTests`, each with its own `StubServer` serving the fixture tile 12/2187/1455 at `https://tiles.example.org/12/2187/1455`, through `Terrain(providers: [provider], …)` and `samples(at:zoomLimits:)` at a point in that tile: "online samples equal the local ones"; "every request carries the User-Agent and no cache header" (`User-Agent == "Test/1 Maqs/0.1.0"`, no `Cache-Control`, no `Pragma`); "404 is noData"; "500 is networkFailure"; "a transport error is networkFailure"; "garbage is networkFailure"; "a 429 starts the cool-down" (first `.rateLimited`; a second call at +30 s on a test clock makes no request and is `.rateLimited`; at +61 s it requests again); "one request for a tile many callers want" (two concurrent calls, response delay 0.3 s, `server.requests.count == 1`); **Review Focus 5:** "a cancelled waiter leaves the fetch for the others" (three callers on a 0.3 s response, cancel one: it throws `CancellationError`, the other two get the elevation, a later call succeeds with at most one more request); "the per-call cap is 128" (129 points in distinct z12 tiles, every route 404: 128 requests, results 128 × `.noData` and 1 × `.requestCap`).
- [ ] **Step 2: Run** the four suites. Expected: FAIL.
- [ ] **Step 3: Implement** the types above. `OnlineTerrainSource.init` validates with `URLComponents` after substituting `0` for the placeholders.
- [ ] **Step 4: Add the guard step** to `swift.yml`'s `guards` job: extract `static let string = "…"` from `Sources/MaqsCore/MaqsVersion.swift` and `Sources/MaqsTerrain/TerrainVersion.swift` with `grep -o`, fail when either is empty or they differ, with a message naming both values. Run `cd pipeline && uv run pytest tests/test_workflows.py -q`. Expected: PASS.
- [ ] **Step 5: Run** the four suites and `swift build`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(terrain): online terrain tiles with User-Agent, HTTP cache, 429 cool-down and a per-call cap`.

### Task 7: Public configuration, point, batch and grid

**Files:**
- Create: `Sources/MaqsTerrain/Public/{TerrainConfiguration,TerrainArea,ElevationGrid}.swift`, `Tests/MaqsTerrainTests/{TerrainConfigurationTests,ElevationTests,GridTests}.swift`
- Modify: `Sources/MaqsTerrain/Terrain.swift`

**Interfaces:**
- Consumes: Tasks 5–6.
- Produces:

```swift
public struct TerrainConfiguration: Sendable {
    public var archives: [URL]
    public var online: OnlineTerrainSource?
    public var userAgent: String
    public var memoryCacheBytes: Int = 64 << 20
    public var diskCacheBytes: Int = 64 << 20
    public init(archives: [URL], online: OnlineTerrainSource? = nil, userAgent: String = "")
    var urlSessionConfiguration: URLSessionConfiguration = .default          // test seam; copied, never mutated
    var cacheDirectory: URL? = <Caches>/Maqs/terrain-tiles                   // test seam
    var now: @Sendable () -> ContinuousClock.Instant = { .now }              // test seam
}
public struct TerrainArea: Sendable, Equatable {
    public init(southWest: CLLocationCoordinate2D, northEast: CLLocationCoordinate2D) throws(TerrainError)   // invalidArea: non-finite, inverted, span > 2°
    public let southWest: CLLocationCoordinate2D; public let northEast: CLLocationCoordinate2D
}
public struct ElevationGrid: Sendable {
    public let area: TerrainArea; public let columns: Int; public let rows: Int
    public let samples: [ElevationSample]                                   // row-major from the north-west cell centre
    public subscript(column: Int, row: Int) -> ElevationSample { get }
}
extension Terrain {   // the init lives in Terrain.swift: actor initializers in extensions must delegate
    public init(configuration: TerrainConfiguration) throws                 // builds the providers, then self.init(providers:memoryCacheBytes:); invalidConfiguration when online is set and userAgent is blank
    public func setArchives(_ urls: [URL]) throws                          // replaces the local providers, clears the cache
    public func elevation(at coordinate: CLLocationCoordinate2D) async throws -> ElevationSample
    public func elevations(at coordinates: [CLLocationCoordinate2D]) async throws -> [ElevationSample]
    public func grid(_ area: TerrainArea, columns: Int, rows: Int) async throws -> ElevationGrid
}
```

The full User-Agent is `"\(userAgent) Maqs/\(TerrainVersion.string)"`. `elevation(at:)` and `elevations(at:)` use zoom limit `Int.max`. `grid` samples cell centres, and its zoom limit is the coarsest `z` in `0...22` with `WebMercator.pixelSize(zoom: z, tileSize: 512, latitude: centre) <= spacing / 2`, where `spacing` is the smaller of the column and row spacing in metres at the centre latitude (22 when none qualifies).

- [ ] **Step 1: Write failing tests.** `TerrainConfigurationTests`: "a blank User-Agent with an online source is rejected" (`""` and `"  "`); "a blank User-Agent without one is fine"; "a basemap archive is not terrain"; "a corrupt archive throws a PMTilesError"; "setArchives clears the cache" (`cachedBytes == 0` after). `ElevationTests`: "elevation matches the golden points" (public API, 1e-6, `null` ↔ `.missing(.noData)`); "a route keeps its order"; "no archives means noData everywhere, then setArchives brings values". `GridTests`: "a small grid equals point samples" (4 × 4 inside the test bbox; each cell equals `elevation(at:)` of its centre); "a large area samples at a coarse zoom" (`SyntheticTerrain` recording loads; area `(45.0, 11.0)–(47.0, 13.0)`, 10 × 10: every loaded key has `z == 3`); `TerrainArea` rejects NaN, inverted corners and a 2.5° span (`invalidArea`); **Review Focus 2:** grid with 0 or 1,025 columns or rows is `invalidInput` and loads no tile.
- [ ] **Step 2: Run** the three suites. Expected: FAIL.
- [ ] **Step 3: Implement** the public API over Task 5's core; `init(configuration:)` builds a `LocalTileProvider` per archive and, when `online` is set, an `OnlineTileProvider` with the seams.
- [ ] **Step 4: Run** the three suites and `swift test`. Expected: PASS, every earlier suite included.
- [ ] **Step 5: Commit** `feat(terrain): public Terrain actor with point, route and grid sampling`.

### Task 8: Geodesy and profiles

**Files:**
- Create: `Sources/MaqsTerrain/Geodesy/Geodesy.swift`, `Sources/MaqsTerrain/Public/{EarthModel,ZoomBands,ProfileOptions,ElevationProfile}.swift`, `Tests/MaqsTerrainTests/{GeodesyTests,EarthModelTests,ZoomBandsTests,ProfileTests}.swift`
- Modify: `Sources/MaqsTerrain/Terrain.swift`

**Interfaces:**
- Consumes: Task 5's `locate`/`load`, Task 7's `Terrain`.
- Produces:

```swift
enum Geodesy {                                     // sphere of radius 6_371_008.8 m, whatever the EarthModel
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double          // haversine
    static func initialBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double    // degrees, [0, 360)
    static func destination(from: CLLocationCoordinate2D, bearing: Double, distance: Double) -> CLLocationCoordinate2D  // lon in [-180, 180)
    static func intermediate(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D
}
public struct EarthModel: Sendable, Equatable {
    public var radius: Double = 6_371_008.8; public var refraction: Double = 0.13
    public init(radius: Double = 6_371_008.8, refraction: Double = 0.13)
    public static let none: EarthModel                 // radius .infinity: no curvature, no refraction
    public func drop(atDistance d: Double) -> Double   // d² / (2R) × (1 − k); 0 for `.none`
}
public struct ZoomBand: Sendable, Equatable { public let upTo: Double; public let zoom: Int; public init(upTo: Double, zoom: Int) }
public struct ZoomBands: Sendable, Equatable {
    public init(_ bands: [ZoomBand]) throws(TerrainError)   // invalidInput: empty, upTo not increasing, last not .infinity, zoom outside 0...22
    public static let standard: ZoomBands                   // (10_000, 12), (30_000, 11), (40_000, 10), (.infinity, 9); built with an internal unchecked init, never try!
    public func zoom(atDistance d: Double) -> Int           // the first band with d <= upTo
}
public struct ProfileOptions: Sendable, Equatable {
    public var step: Double? = nil      // nil: WebMercator.pixelSize of the band's zoom, 512 px, at the start latitude
    public var earth: EarthModel = .init(); public var bands: ZoomBands = .standard
    public init(step: Double? = nil, earth: EarthModel = .init(), bands: ZoomBands = .standard)
}
public struct ProfilePoint: Sendable {
    public let distance: Double; public let coordinate: CLLocationCoordinate2D
    public let ground: ElevationSample; public let apparentElevation: Double?   // nil exactly when ground is missing
}
public struct ElevationProfile: Sendable { public let points: [ProfilePoint] }
extension Terrain {
    public func profile(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, options: ProfileOptions = .init()) async throws -> ElevationProfile
}
```

Points: distance 0, then `d += step(band at d)` while `d < total`, then `total` itself; coordinates by `intermediate(fraction: d / total)`; zoom limit `bands.zoom(atDistance: d)`.

- [ ] **Step 1: Write failing tests.** `GeodesyTests`: 1° of longitude on the equator is 111,195.08 m (±0.01); bearing (0,0)→(1,0) is 0 and (0,0)→(0,1) is 90; destination (0,0), 90°, 111,195.08 m is (0, 1) within 1e-9; **Review Focus 3:** destination from (0, 179.5) east by 1° is (0, −179.5); the midpoint of (0,0)–(0,10) is (0,5). `EarthModelTests`: drop at 10 km is 7.848 (k 0) and 6.828 (k 0.13), at 100 km 784.8 and 682.8 (±0.001); `.none` drops 0. `ZoomBandsTests`: standard gives 12 at 5 km and at exactly 10 km, 11 at 10,001 m, 10 at 35 km, 9 at 50 km; rejects decreasing bands, a missing `.infinity`, zoom 23. `ProfileTests` over `SyntheticTerrain(elevation: { _, _ in 1000 })`: first point at 0, last at the total distance; spacing of the first two points equals `pixelSize(12, 512, start latitude)` within 1e-6; `apparentElevation == 1000 − drop(d)` for every point; loaded zooms switch from 12 to 11 at 10 km on a 15 km profile; a gap gives `.missing(.noData)` with `apparentElevation == nil`; **Review Focus 2:** step 0.5, NaN endpoints and a profile of more than 100,000 points are `invalidInput`.
- [ ] **Step 2: Run** the four suites. Expected: FAIL.
- [ ] **Step 3: Implement** the types above.
- [ ] **Step 4: Run** the four suites. Expected: PASS.
- [ ] **Step 5: Commit** `feat(terrain): great-circle profiles with curvature, refraction and distance bands`.

### Task 9: Visibility

**Files:**
- Create: `Sources/MaqsTerrain/Terrain+Visibility.swift`, `Sources/MaqsTerrain/Public/{Observer,SightTarget,VisibilityOptions,Visibility}.swift`, `Tests/MaqsTerrainTests/VisibilityTests.swift`

**Interfaces:**
- Consumes: Tasks 5, 7, 8.
- Produces:

```swift
public enum ObserverHeight: Sendable, Equatable { case aboveGround(Double), absolute(Double) }
public struct Observer: Sendable { public var coordinate: CLLocationCoordinate2D; public var height: ObserverHeight = .aboveGround(1.7)
    public init(coordinate: CLLocationCoordinate2D, height: ObserverHeight = .aboveGround(1.7)) }
public struct SightTarget: Sendable { public var coordinate: CLLocationCoordinate2D; public var elevation: Double?
    public init(coordinate: CLLocationCoordinate2D, elevation: Double? = nil) }
public struct VisibilityOptions: Sendable, Equatable {
    public var maxDistance: Double = 100_000; public var margin: Double = 10; public var targetClearance: Double = 150
    public var earth: EarthModel = .init(); public var bands: ZoomBands = .standard
    public init(...)   // same defaults
}
public enum Visibility: Sendable {
    case visible(distance: Double, bearing: Double, elevationAngle: Double)   // degrees; angle from atan2(target apparent − observer, distance)
    case hidden(distance: Double, blockedAt: CLLocationCoordinate2D, blockedDistance: Double, clearance: Double)
    case unknown(at: MissingHeight, reason: MissingReason, distance: Double)
    case outOfRange(distance: Double)
    public enum MissingHeight: Sendable, Equatable { case observer, target, path }
}
extension Terrain {
    public func visibility(of targets: [SightTarget], from observer: Observer, options: VisibilityOptions = .init()) async throws -> [Visibility]
}
```

The algorithm is the spec's *Visibility* section, steps 1–7. Additions: the observer's ground is sampled at `bands.zoom(atDistance: 0)`, a target's ground at `bands.zoom(atDistance: distance)`; samples run from one step past the observer to `distance − targetClearance` (none when that is ≤ 0); the hiding sample is the one with the largest clearance above `margin`; a target closer than 1 m is `.visible(distance:, bearing: 0, elevationAngle: 0)`; targets are processed in bearing order in chunks small enough that one chunk's tiles fit the cache (chunk size is the builder's call), and results return in input order.

- [ ] **Step 1: Write failing tests**, over `SyntheticTerrain` (flat 0 m unless stated), observer `(46.0, 12.0)` at `.absolute(1000)`, `earth: .none` unless stated: "flat ground shows a target" (placed with `Geodesy.destination(from:bearing: 90, distance: 20_000)`, elevation 1000: `.visible`, angle 0 ±1e-9, bearing 90 ±1e-6); "a ridge hides it" (1500 m between lon 12.06 and 12.07: `.hidden`, `blockedDistance` 4–6 km, `clearance` ≈ 500); "a ridge within the margin does not" (1008 m); "the target's own slope is ignored" (ground 1050 m within the last 140 m, target 1000: visible; with `targetClearance: 0`, hidden); "the true summit makes a peak visible" (ridge 1100 m at 5 km, target ground 1000: hidden without `elevation`, visible with `elevation: 1600`); "a gap is unknown" (no tile whose longitude range overlaps 12.15–12.16, target elevation 1000: `.unknown(at: .path, reason: .noData)`; at z11 and z12 that gap is a different tile from the ridge's); "a known ridge beats a gap" (that gap plus the 1500 m ridge: `.hidden`); "beyond the range is outOfRange" (150 km); "an unknown observer" (`.aboveGround` in a gap: `.unknown(at: .observer, …)`); "an unknown target" (a gap over the target's tile, no `elevation`: `.unknown(at: .target, …)`; with `elevation`, the ground before it is in the same gap: `.unknown(at: .path, …)`); "curvature hides a distant low target" (observer `.absolute(2)`, target 50 km at elevation 100, `margin: 0`: hidden with the default earth, visible with `.none`); "results keep input order" (targets north, south, east); **Review Focus 1:** "a target at the observer is visible with finite values"; **Review Focus 2:** "a NaN target is unknown" (`.unknown(at: .target, reason: .noData, distance: 0)`), "a NaN observer is invalid input", "5,001 targets are invalid input".
- [ ] **Step 2: Run** `swift test --filter VisibilityTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the query.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(terrain): line-of-sight visibility that leans toward visible and never guesses`.

### Task 10: Measure, then the simulator

**Files:**
- Create: `Tests/MaqsTerrainTests/FullLookMeasurement.swift`

- [ ] **Step 1: Write the measurement test** `FullLookMeasurement` ("a full look is measured"): a `TileProvider` (test target) whose `load` decodes the fixture tile 12/2187/1455 with `TerrariumDecoder` on every call and serves it for any key; 200 targets at bearings 0°, 1.8°, … and distances 10–100 km around `(46.10, 12.25)`; the default options and cache. It prints elapsed time, decode count and the largest `cachedBytes` seen, and asserts only that every result is one of the four cases.
- [ ] **Step 2: Run** `swift test --filter FullLookMeasurement` on macOS and `xcodebuild -scheme Maqs-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`. Expected: both green; grep the xcodebuild log for `": error:"` (none) and read the `Test run with N tests` line. Record time, decodes and peak cache bytes for ADR 0015. If a full look takes 2 s or more locally, parallelise decoding in `Terrain.load` (a task group over the misses) and measure again; record both numbers.
- [ ] **Step 3: Commit** `test(terrain): measure a full look`.

### Task 11: Documentation

**Files:**
- Modify: `docs/decisions.md` (ADR 0015; ADR 0008's status line notes the pixel-size correction), `docs/data-format.md`, `docs/architecture.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: ADR 0015 — `MaqsTerrain`** (date, status accepted with the owner's decisions of 2026-10-24 to 26, context, decisions, consequences): the spec's twelve decisions; `OnlineTerrainSource` closing ADR 0014's open question for terrain; the shared sampling rule; the zoom bands with the tile counts (743 / 93 / 69 / 50); visibility semantics and defaults; `ElevationSample` with `MissingReason`; caches and their bounds; the 429 policy and the 128 cap as unverified guesses at a safe pace; the privacy figure (about 500 m for a full online look, a review estimate); the facts verified on 2026-10-25 (lossless WebP, ImageIO equals Pillow, raw DEFLATE, `CLLocationCoordinate2D` is `Sendable` on macOS and the iOS Simulator SDKs); Task 10's measurements; the z12 pixel size correction to ADR 0008 (about 13.3 m, not 27 m).
- [ ] **Step 2: `docs/data-format.md`:** a § *Elevation sampling* section with the rule (Web Mercator position, `+0.5` pixel centres, bilinear within the tile, clamped, no cross-tile interpolation, terrarium formula, ±85.05° limit); the trails *Ascent and descent* paragraph links to it instead of restating it.
- [ ] **Step 3: `docs/architecture.md` § Swift package:** `MaqsTerrain` available; its imports; the source order and the zero-request rule inside an installed region; the online path (User-Agent, HTTP cache, cool-down, cap); the privacy note; the `TileSource` → `OnlineTerrainSource` mapping; remove `MaqsTerrain` from the open question that ADR 0014 left.
- [ ] **Step 4: `README.md`:** the product in the Swift package section and a short example: build `Terrain` from an installed pack's terrain file URLs and `maqs.onlineSources?.terrain.first` mapped to `OnlineTerrainSource`, then `visibility(of:from:)`.
- [ ] **Step 5: `CLAUDE.md` §1:** *Where we are* (MaqsTerrain done, ADR 0015; MaqsData next); the stack summary and repository map (`Tests/MaqsTerrainTests/`, `terrain-golden.json`, `scripts/update-terrain-golden.sh`); the commands (`xcodebuild -scheme Maqs-Package …`, `scripts/update-terrain-golden.sh`); *Things that will bite you*: `COMPRESSION_ZLIB` is raw DEFLATE so gzip headers are parsed by hand, ImageIO's pixel layout is checked before reading provider bytes, the version strings of `MaqsCore` and `MaqsTerrain` must match (guarded in `swift.yml`), and anything else found while building.
- [ ] **Step 6:** Run the prose through the `humanizer` skill (CLAUDE.md §13), then `cd pipeline && uv run pytest -q` (the docs tests, such as attribution agreement, still pass) and `swift test`. Expected: PASS.
- [ ] **Step 7: Commit** `docs: ADR 0015 MaqsTerrain; elevation sampling, architecture, README, CLAUDE.md`.

---

After Task 11: a fresh-context review of the whole branch against CLAUDE.md §12, then the done list of CLAUDE.md §3 (`swift build`, `swift test`, the simulator leg, `uv run pytest`, ruff), with the exact commands and results in the report.
