# maqs

Map data and a Swift package for native Apple apps: Shortbread basemap tiles, terrarium terrain, hiking trails, places and road curvature, per region. Online-first, offline optional, zero hosting cost: code in this repository, data as GitHub Release assets, compute in GitHub Actions. One map provider, [VersaTiles](https://versatiles.org), serves every tile online and offline.

**Status:** the pipeline builds all five layers of a region (basemap, terrain, trails, places, curvature) and the bundled base packs, and writes `manifest.json` from the build reports. A GitHub Actions workflow builds every region each month and publishes the files as a release. The Swift package has three of its four products: `MaqsCore`, which discovers, downloads and installs region packs, `MaqsTerrain`, which reads elevations and tells which peaks the user can see, and `MaqsData`, which searches trails, finds places along a bearing and looks up the corners ahead on a road; the map product comes next. [`docs/BRIEF.md`](docs/BRIEF.md) has the plan and [`docs/decisions.md`](docs/decisions.md) has every decision and the numbers behind it.

## Data releases

A GitHub Actions workflow, [`build-maps.yml`](.github/workflows/build-maps.yml), builds every region at 03:00 UTC on the 1st of each month and publishes a GitHub Release tagged `data-YYYY-MM`, marked latest. Each release holds a `manifest.json`, the base pack files, and the files of every region in `config/regions.yaml` except the `test` fixture. The first release, `data-2026-10`, is published. Clients read `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json`, which lists each file with its size, its SHA-256 and a URL pinned to its release. The online tile sources are in [`config/sources.json`](config/sources.json), which clients read from `main`. A client picks the files it can read by the [compatibility rule](docs/data-format.md#compatibility-rule).

To run the workflow by hand, for example after a failed month:

```sh
gh workflow run build-maps.yml                 # every region and the base packs; publishes this month's release
gh workflow run build-maps.yml -f region=test  # one region (or base): builds it and uploads the dist-test artifact; publishes nothing
```

A run in a month that already has a release deletes and re-uploads that release's files of the same name, the manifest last. It never touches an older release, and when it succeeds every file the new manifest names is there. Only a run on `main` publishes. A dispatch with `-f region=…` or `-f layers=…`, or one on another branch with `--ref`, only builds, and keeps its outputs as workflow artifacts for 7 days. [`docs/architecture.md`](docs/architecture.md#data-releases) explains the jobs, and ADR 0013 in [`docs/decisions.md`](docs/decisions.md) gives the reasons.

## Swift package

The `Maqs` Swift package (iOS 18, macOS 15) reads these releases on the device. It has four products, so an app links only what it uses:

| Product | What it does | State |
|---|---|---|
| `MaqsCore` | the region catalog from the latest manifest, verified downloads and installs, the online tile sources | built and tested, unreleased |
| `MaqsTerrain` | elevation at a point, along a route, on a grid or along a profile, and line of sight, from installed packs or online tiles | built and tested, unreleased |
| `MaqsData` | trail search, places along a bearing, road segments and the corners ahead, from the installed files | built and tested, unreleased |
| `MaqsUI` | a SwiftUI map view over MapLibre Native, iOS only | planned |

No package version is tagged yet; the first tag comes once all four products are built.

`MaqsCore` uses system frameworks only. A minimal use, from the main actor:

```swift
import MaqsCore

var configuration = MaqsConfiguration(layers: [.basemap, .terrain, .trails], userAgent: "MyApp/1.0 (iOS)")
configuration.backgroundSessionIdentifier = "com.example.myapp.maqs"  // iOS: downloads go on in the background
let maqs = try Maqs(configuration: configuration)                     // once per process, on the main actor

let catalog = try await maqs.refreshCatalog()                         // what the latest data release offers
for region in catalog.regions {
    print(region.names["en"] ?? "", region.totalBytes, region.status)
}
try await maqs.install(.region("veneto"))                             // size and SHA-256 checked, then moved into place
print(maqs.state.packs[.region("veneto")] ?? .notInstalled)           // the state SwiftUI observes
if let pack = await maqs.installedPack(.region("veneto")) {
    print(pack.files[.terrain]?.first?.url as Any)                    // a file URL to hand to MaqsTerrain
}
```

The `userAgent` names your app, because the free tile providers ask for an identifying User-Agent. On iOS, forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `maqs.handleEventsForBackgroundURLSession(identifier:completionHandler:)`. After a relaunch, call `install` again for the packs the user had asked for, because the package does not remember them; the call joins a download that is still running, or reuses one that finished after a size and hash check, instead of downloading it again. Set `onlineTiles` to `false` and the package hands out no online tile source, so no position leaves the device through it. [`docs/architecture.md`](docs/architecture.md#swift-package) explains discovery and installs, and ADR 0014 in [`docs/decisions.md`](docs/decisions.md) gives the reasons.

`MaqsTerrain` also uses system frameworks only, and it never imports `MaqsCore`: the app hands it the terrain files of the installed packs and, for everywhere else, the online terrain source. Continuing the example:

```swift
import CoreLocation
import MaqsTerrain

let pack = await maqs.installedPack(.region("veneto"))
let archives = [Layer.terrain, .terrainHD].flatMap { pack?.files[$0] ?? [] }.map(\.url)

// nil when onlineTiles is false: then MaqsTerrain never makes a request
let online = try await maqs.onlineSources?.terrain.first.map { source in
    try OnlineTerrainSource(tiles: source.tiles, format: source.format, tileSize: source.tileSize ?? 512,
                            minZoom: source.minZoom, maxZoom: source.maxZoom)
}
let terrain = try Terrain(configuration: TerrainConfiguration(archives: archives, online: online,
                                                              userAgent: "MyApp/1.0 (iOS)"))

let here = CLLocationCoordinate2D(latitude: 46.10, longitude: 12.25)
print(try await terrain.elevation(at: here))                      // .elevation(metres) or .missing(reason)

let peak = SightTarget(coordinate: CLLocationCoordinate2D(latitude: 46.21, longitude: 12.18),
                       elevation: 2_145)                           // the summit's OSM ele, when known
for result in try await terrain.visibility(of: [peak], from: Observer(coordinate: here)) {
    switch result {
    case .visible(let distance, let bearing, let angle): print("visible", distance, bearing, angle)
    case .hidden(_, _, let blockedDistance, _): print("hidden by ground", blockedDistance, "m away")
    case .unknown(_, let reason, _): print("unknown", reason)      // ground missing, or online tiles failed
    case .outOfRange: print("too far")
    }
}
```

Inside an installed region the elevations come from the pack, and a look fetches online only the ground beyond the pack's border. Elsewhere the package fetches VersaTiles' tiles through the HTTP cache, at most four at a time and 128 per call, and pauses after a 429. A missing value carries its reason, so an app can tell "no data here" from "try again later". Create one `Terrain` and share it: the pause after a 429, the limit of four requests and the HTTP cache directory belong to one instance, so a second instance would double the requests and ignore the first one's pause. The tiles of one online look give away roughly where the user stands, to about 500 m; an app that must not reveal that sets `onlineTiles` to `false`, and `onlineSources` is then nil. After an install, an update or a removal, pass the new file URLs to `terrain.setArchives(_:)`. [`docs/architecture.md`](docs/architecture.md#terrain) describes the sources, the results and the online path, and ADR 0015 in [`docs/decisions.md`](docs/decisions.md) gives the reasons.

`MaqsData` imports no other product either: it takes the SQLite files of the installed packs and works offline. Continuing the example (`MaqsCore` is imported only for `Layer` and the installed `pack`; `terrain`, `here` and `Observer` come from the `MaqsTerrain` block):

```swift
import MaqsCore
import MaqsData
import MaqsTerrain

// the SQLite files only: trails and places also list a tile overlay, with role "overlay"
let files = { (layer: Layer) in (pack?.files[layer] ?? []).filter { $0.role == nil }.map(\.url) }
let trails = try Trails(files: files(.trails))
let places = try Places(files: files(.places))
let roads = try Roads(files: files(.curvature))

// Trail search: the exact number first, then numbers inside a ref (926A, E926), then text.
for trail in try await trails.search("926", near: here, limit: 5) {
    print(trail.ref ?? "", trail.name ?? "", trail.geometryStatus)
}

// Places along a sight line: a cone from where the user stands, handed to MaqsTerrain.
let cone = try BearingCone(origin: here, bearing: 40, halfAngle: 5, maxDistance: 100_000)
let targets = try await places.places(in: cone, kinds: [.peak], limit: 20)
    .map { SightTarget(coordinate: $0.place.coordinate, elevation: $0.place.elevation) }
let looks = try await terrain.visibility(of: targets, from: Observer(coordinate: here))

// Corners ahead: the app matches the position to a segment, MaqsData walks on from there.
if let near = try await roads.segments(near: here).first {
    let position = RoadPosition(segment: near.segment, direction: .forward, along: near.along)
    let ahead = try await roads.cornersAhead(from: position, distance: 1_000)
    for corner in ahead.corners {
        print(corner.turn, corner.minRadius, corner.entry, corner.afterFork)  // afterFork: past a guessed branch
    }
}
```

Matching a position to a road, and choosing the direction of travel, stay with the app; `MaqsData` returns the segments near a position, with the heading at the nearest point, to match against. Where the road forks, the lookahead takes the likeliest branch (same `ref`, then `name`, then `highway`, then the smallest turn) and marks the corners after it. After an install, an update or a removal, pass the new URLs to `setFiles(_:)` on each reader: SQLite fails reads from a file that was replaced while open. Curvature files built before the `junctions` table (`data-2026-10`) only link roads at way ends, so the lookahead stops at many ordinary junctions until the next monthly release. [`docs/architecture.md`](docs/architecture.md#data) describes the readers, and ADR 0016 in [`docs/decisions.md`](docs/decisions.md) gives the rules and the measurements.

`swift build` and `swift test` run from a clean checkout: the tests read the `test` region's files committed under `Tests/MaqsTestSupport/Fixtures/`. `scripts/update-fixtures.sh` rebuilds them with the pipeline, writes the pipeline's terrain and data-layer values that the Swift tests compare against, and refreshes the copy of `sources.json` bundled in the package.

## Build a region locally

```sh
pipeline/bootstrap.sh            # installs versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu 24.04)
cd pipeline && uv sync
uv run maqs check-tools
uv run maqs build --region test  # all five layers and build-report.json in dist/test/ at the repository root
uv run maqs build --region veneto
uv run maqs build --region veneto --layers basemap,terrain  # only some layers
uv run maqs build --region base  # the base packs, in dist/base/
uv run maqs regions
```

Outputs go to `dist/<region>/` at the repository root, even when you run from `pipeline/`; `--dist` overrides it. A full build writes `<region>-basemap.v1.pmtiles`, `<region>-terrain.v1.pmtiles`, `<region>-trails.v1.sqlite`, `<region>-trails.v1.pmtiles`, `<region>-places.v1.sqlite`, `<region>-places.v1.pmtiles`, `<region>-curvature.v1.sqlite` and `build-report.json`, all described in [`docs/data-format.md`](docs/data-format.md). The `.v1` is the layer's schema version. The trails, places and curvature layers read the region's Geofabrik extract (about 625 MB for `europe/italy/nord-est` in October 2026), downloaded once into `.cache/` and reused; delete it to get a fresh one. Adding a region anywhere in the world is one entry in `config/regions.yaml` when the region is cut from the `europe/italy/nord-est` extract; a region from another Geofabrik extract also needs an edit to `.github/workflows/build-maps.yml` (ADR 0013). [`docs/architecture.md`](docs/architecture.md) lists the fields.

## Develop

```sh
cd pipeline
uv run pytest -q                 # unit tests, no network
uv run pytest --run-network -q   # plus the live test-region build; downloads the Geofabrik extract into .cache/ once
uv run ruff check . && uv run ruff format .
uv run maqs check-config         # regions.yaml, and sources.json against its schema
uv run maqs manifest --release data-ci --regions test  # dist/manifest.json from the test and base builds; data-ci is never published
```

## Licences

Code: Apache-2.0 ([`LICENSE`](LICENSE)). Data: OpenStreetMap under the ODbL, plus the attributions in [`DATA_LICENSE.md`](DATA_LICENSE.md).
