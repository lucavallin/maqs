# Swift package, sub-project 4: `MaqsUI` and the demo app — design

**Date:** 2026-10-28 · **Status:** draft, for the owner's review
**Brief:** `docs/BRIEF.md` § Phase 4, MaqsUI and Demo · **Builds on:** ADR 0001 (MapLibre facts), 0003 (iOS only), 0004 (VersaTiles), 0007 (base pack), 0008 (privacy, the `onlineTiles` opt-out), 0012 (`sources.json`), 0014 (`MaqsCore`), 0015 (`MaqsTerrain`; the online etiquette copied here), 0016 (`MaqsData`; overlay feature ids)

## Problem

`MaqsUI` is the map: a SwiftUI view over MapLibre Native that shows the basemap online or from installed regions, draws what an app hands it, and credits the sources it shows. Three kinds of screens set the requirements (owner, 2026-10-28):

1. **A ride.** The map follows the rider, turned to the heading or the course, and the recorded track is a line that grows behind them.
2. **A hike.** A trail picked from the trails layer is drawn in the accent, the others quieter, deep in valleys with no signal.
3. **A sight line.** A great-circle line runs from the user along a bearing, the places along it are markers, and the stretches out of sight are drawn differently.

Each app's logic (recording, the corner alert, the sight-line maths, search) stays in the app. `MaqsUI` gives it a map to draw on.

## Approaches considered

**What `MaqsUI` is:**

1. **A complete wrapper** (chosen, owner): a SwiftUI view and an observable model; apps describe lines, markers and overlays as values and never import MapLibre. A MapLibre upgrade touches one module; the cost is a larger API that grows when an app needs something new.
2. **Style assembly plus the raw `MLNMapView`.** Smaller, but every app would learn MapLibre, its Objective-C exceptions and its threading, and the vendor boundary would end at the app. Rejected by the owner.
3. **MapLibre's separate `swiftui-dsl` package.** A second dependency, which CLAUDE.md forbids.
4. **Nothing in the package.** Every app would repeat the offline switching, the User-Agent, the rate-limit etiquette and the attribution, and disagree.

**How the map switches between downloaded files and online tiles** (the brief asks for an ADR):

1. **A tile gateway** (chosen, the designer's call): the style has one basemap source and one terrain source whose tile URLs are the provider's. A `URLProtocol` registered on MapLibre's own session answers each tile request: from an installed pack when one covers the tile, otherwise from the network, through its own session, with the rate-limit pause. One set of layers, so no seam at a region's edge and no duplicated labels; no online request for any tile a pack covers, even with signal; app styles stay unchanged.
2. **Layered sources:** one `pmtiles://` source per installed pack plus the online source, every style layer copied per source, local copies drawn above. Uses MapLibre as designed, but research (below) found no way to exclude an area from a source: inside a region the online tiles are still requested and drawn underneath, translucent layers draw twice (a visible seam at the bbox), and three installed regions turn the default style's 257 layers into about 1,300. It is the fallback if the gateway's spike fails.
3. **Swapping the style as the camera crosses a region's edge.** MapLibre drops a removed source's tiles at once, so the map would flash at every crossing.

The gateway is needed for etiquette anyway: MapLibre answers a 429 without `Retry-After`, VersaTiles' case, by retrying every tile every 5 s with no backoff, as long as the tile is in view. Only something that sees the responses can pause.

## Decisions

Made by the owner in conversation (2026-10-28):

1. **`MaqsUI` is only about maps.** It shows maps online and offline and lets an app draw on them; it holds no app logic.
2. **Apps never import MapLibre.** `MaqsUI` wraps it completely and grows when an app needs more.
3. **Switching:** inside an installed region the map always draws from the downloaded files, even with signal *(proposed by the designer, accepted)*. Outside installed regions it streams when there is signal; with none it shows what MapLibre cached from earlier viewing, best effort, so a place never seen stays blank. Where local meets online there is no visible seam *(proposed, accepted)*. Hillshade follows the same rules.
4. **The download offer is the app's.** `MaqsUI` reports whether the device is offline and which catalog region under the map is not installed; the app decides when and how to ask. The install is `MaqsCore`'s, and the map uses the new files when it finishes, with no restart.
5. **The look follows the package's map design rules** (accepted in the playback): a muted light and dark base map; the one active line in the accent, 5 pt on an 8 pt casing; other lines grey 4 pt on casing; hidden lines grey 3 pt, dashed 4–5, no casing, under the solid ones; an optional accent glow for live lines on dark maps; round 30 pt markers with a 2 pt white ring and a 44 pt hit area, app content inside; the trail-number plate as the one non-round marker; a selected marker 1.25× with an accent halo, one at a time; the user's location blue, never the accent. Points of interest are off unless the app turns a category on. No satellite.
6. **Apps draw the chrome** (scrim, chips, controls, selection card, sheet, offline banner, loading ring) in SwiftUI. `MaqsUI` hides MapLibre's compass, logo and attribution button and gives the app the camera actions behind its own buttons. The attribution view is `MaqsUI`'s, for the app to place in its chrome.
7. **No app knowledge** in this sub-project: no app name, no app feature.

**The designer's calls,** for the owner to check while reading:

- **The tile gateway** (above), with the layered-sources design as the fallback.
- **`MaqsUI` depends on `MaqsCore`.** Every map needs `sources.json` and the installed packs, so this forces no extra product on an app. It does not depend on `MaqsData` or `MaqsTerrain`: a tap returns a region and a feature id, and the app asks `MaqsData`.
- **The PMTiles reader moves into an internal target, `MaqsPMTiles`** (not a product), used by `MaqsTerrain` and `MaqsUI`, so `MaqsUI` does not link `MaqsTerrain`. Cross-module internals use Swift's `package` access level, not `public`; `MaqsConfiguration.fullUserAgent` becomes `package`.
- **Subtle hillshade is on by default**, and an app can turn it off. Online it adds the terrain tiles of the view, about four to six 512 px tiles, to the basemap's.
- **Text on the map uses Noto Sans,** regular and bold, bundled; marker labels are Noto Sans Bold 13 with a halo in the casing colour. SF Pro cannot be a glyph font; MapLibre renders text from SDF glyph files.
- **Markers are style layers with images drawn at run time,** not UIKit views: they stay fast with hundreds of places, collide with labels and need no assets. The location puck is a MapLibre view above every layer, so a selected marker under the user's position sits below the puck, not above as the design rules order it.
- **The default style starts from VersaTiles' `muted` and `muted-dark`** (CC0), recoloured to the design's map colours by a script, not by hand.
- **The demo downloads a real region.** The brief's demo step "download the test region" cannot run: the `test` region is a fixture and its `data-ci` manifest is never published. The demo installs `friuli-venezia-giulia`, the smallest released region, with basemap, terrain, trails and places, about 230 MB.

**Settled after the builder check,** from the existing ADRs and the designer's judgement:

- **Base packs sit below online tiles** (ADR 0007: "the lowest-priority tile source, below downloaded packs and online tiles"). Region packs answer first, then the network, and the base pack only when the online answer cannot come (below).
- **The map uses only the layers the app configured** (ADR 0008, decision 3: every online request is attributable to a layer the app enabled). `MaqsMap.init` throws when `.basemap` is not in `MaqsConfiguration.layers`; hillshade draws only when `.terrain` is configured; inside an installed region the region answers for every configured layer, so a layer it lacks (a `partiallyInstalled` region) is empty there rather than fetched online, which keeps CLAUDE.md's budget of zero network calls inside an installed region.
- **`MaqsPMTiles` keeps `MaqsTerrain`'s public API unchanged:** its reader throws a `package` error type, and `MaqsTerrain` maps it case for case to its public `PMTilesError`.
- **`uninstalledRegion`** is nil when any installed region (status `installed`, `updateAvailable` or `partiallyInstalled`) covers the map's centre; otherwise it is the smallest region whose `bbox` contains the centre, whose status is `notInstalled` and which is not queued or downloading in `MaqsState.packs`. Updates are not this signal: the catalog already reports `updateAvailable`.
- **If MapLibre will not render in the package's hostless test bundle,** the MapLibre tests move to a test target of the demo app, which `swift.yml`'s simulator job then runs instead of only building, so CI still checks the no-network guarantee. The spike settles it.

The builder's calls are marked *(builder's call)* where they appear; anything not marked is required.

## Success criteria

- `MaqsUI` is an iOS 18 product whose only dependency besides `MaqsCore` is MapLibre `6.31.0..<7.0.0`, for iOS only. `swift build`, `swift build --build-tests` and `swift test` on macOS stay green, and run `MaqsUI`'s platform-independent tests; the iOS Simulator leg runs all of them. Warnings are errors everywhere.
- `import MapLibre` appears only under `Sources/MaqsUI/` (the existing guard), and no `MaqsUI` type in the public API is a MapLibre type.
- **No network inside an installed region.** On the simulator, with the `test` region installed and every network request failing, the map loads, and every basemap, terrain, overlay, glyph and sprite request is answered locally: no request reaches the network stub while the camera is inside the region.
- Outside installed packs with signal, tiles come from the `sources.json` provider with the app's `User-Agent`, no request carries a header that disables caching, and after a 429 no tile request reaches the provider until the pause ends.
- With `onlineTiles` false, no request reaches any tile host, inside or outside installed packs.
- Installing or removing a pack while the map is shown changes what it draws without recreating the view; switching light and dark keeps the camera, lines, markers and overlays.
- The bundled default style names no remote URL, every symbol layer names a bundled font stack, and every glyph range it can request exists.
- The attribution view lists exactly the credits of the layers being drawn, is VoiceOver-labelled, scales with Dynamic Type, and its links open.
- A tap on a trail or place in the overlay returns the region and the feature id of the row `MaqsData` returns for it (fixture test).
- The demo goes through the brief's steps by hand on the simulator and on a device, the airplane-mode map on a device.

## Facts verified while designing (2026-10-28)

MapLibre Native iOS at `ios-v6.31.0` (source, the shipped headers, and Swift 6 probes compiled against the binary; details and sources in ADR 0017 when it is written):

- **Package.** A dependency with `condition: .when(platforms: [.iOS])` and sources inside `#if canImport(MapLibre)` keeps `swift build`/`swift test` green on macOS (each target keeps one unguarded file) and builds and tests on the simulator. Without the condition, macOS fails: "While building for macOS, no library for this platform was found". `swift package resolve` fetches the 10.3 MB binary on macOS too.
- **Swift 6.** The headers carry no concurrency annotations. A `@MainActor` class conforming to `MLNMapViewDelegate` is an error ("crosses into main actor-isolated code"); `@preconcurrency import` does not fix it, `NSObject, @preconcurrency MLNMapViewDelegate` does. Off-main use of `MLNMapView` is a warning, so an error here; passing an `MLNStyle` across actors is not diagnosed at all. CI's Xcode 26.6 was not probed.
- **Style.** `MLNMapView(frame:styleJSON:)` takes the JSON directly. `MLNMapView(frame:)` without a style loads `demotiles.maplibre.org`, a host not in `sources.json`. A style load clears every source, layer and image added at run time; `mapView(_:didFinishLoading:)` is where they are added again. A duplicate source or layer id raises an Objective-C exception Swift cannot catch. A style swap keeps the camera once it has moved, and a source with the same id and tiles keeps its tiles.
- **Two sources.** A source's `bounds` stops requests outside it, by whole tiles; a `pmtiles://` source takes its bounds from the archive. Nothing excludes an area from a source; `within` filters points and whole lines only. Removing and adding a source starts it empty.
- **Cache.** The ambient cache is one SQLite file shared by every map view and kept across launches, 50 MiB by default (`MLNOfflineStorage.setMaximumAmbientCacheSize`, before the first map loads). Offline, an expired cached tile still renders unless the server sent `must-revalidate`; `invalidateAmbientCache` marks every tile so and breaks that. Only `max-age` and `must-revalidate` are read, and `Expires` overrides `max-age`. MapLibre's session has no `URLCache`; the `User-Agent` goes into the `sessionConfiguration` MapLibre returns, mutated in place, before any map view exists.
- **Retries.** A 429 without `Retry-After` is retried every 5 s per tile with no growth; connection errors back off from 1 s; a 404 tile is empty, not retried. The map watches reachability and retries connection failures when the network returns. No public API forces offline mode.
- **Glyphs.** Requested per whole font stack, its names joined by a comma; a symbol layer without `text-font` asks for `Open Sans Regular,Arial Unicode MS Regular`. CJK is drawn from a system font by default.
- **Location.** With `showsUserLocation` and the default `shouldRequestAuthorizationToUseLocationServices`, the map asks for when-in-use permission itself and raises an exception, a crash, when `NSLocationWhenInUseUsageDescription` is missing. An app-fed `MLNLocationManager` works. The puck takes the map view's `tintColor`.
- **Attribution.** No public API returns the credits of the visible sources; each `MLNTileSource` has `attributionInfos`.
- **Camera.** `setVisibleCoordinateBounds(_:edgePadding:animated:)` is deprecated (a warning, so an error here); the `completionHandler:` variant is not. `maximumPitch` defaults to 60°.
- **PMTiles headers are cached by URL for the life of the process.** `MaqsCore` already installs each build under its own SHA-256 directory, so a new build is a new URL.

VersaTiles (live pages):

- `versatiles-fonts` v3.0.0 (2026-09-14), `noto_sans.tar.gz`: SDF glyph directories `noto_sans_regular` and `noto_sans_bold`, 256 ranges each. Regular and bold for ranges 0–1023 (Latin, Latin Extended, Greek, Cyrillic; Slovenian needs 256–511) are 831,718 bytes. The fonts are OFL (the archive has no licence file); the repository is MIT.
- `versatiles-style` v7.0.1 (2026-10-15): styles `muted` and `muted-dark` among others, 257 layers in `muted`, CC0; sprite sheet `base` with POI icons (fuel, shelter, chalet, campsite, lodging, viewpoint), CC0. No peak or parking icon in `base`.
- The `osm` tileset is Shortbread 1.0 with exactly its 26 layers. Peaks are not in Shortbread; they come from the places overlay, so online they are absent. `place_labels` carries `name` and `name_de`, `name_en`, `name_it` and eight others, no Friulian or Slovenian.

The package today: `MaqsState` is `@MainActor @Observable` with `packs`; `installedPack(_:)` returns file URLs per layer, the overlay as a second file with `role: "overlay"`; `Catalog.attribution` holds the manifest's credits with their layers; `PackSummary.bbox` is the region's `BoundingBox`; `registerBundledBasePack(id:basemap:)` exists (ADR 0007).

## Package layout

```
Sources/MaqsPMTiles/            # internal target, no product: the PMTiles v3 reader moved from MaqsTerrain, `package` access
Sources/MaqsUI/
  Logging.swift                 # os.Logger, category "ui"
  Style/                        # style assembly: pure JSON, builds on macOS too
  Gateway/                      # tile routing and the rate-limit pause (pure); the URLProtocol (iOS)
  Content/                      # lines, markers, overlays as GeoJSON and layers; marker images (iOS)
  Map/                          # MaqsMap, MaqsMapView, the coordinator (iOS, MapLibre)
  Attribution/                  # credits (pure) and MapAttributionView (iOS)
  Public/                       # value types and MapError, one per file
  Resources/                    # glyphs, sprite, default styles, licences; generated, never hand-edited
Tests/MaqsUITests/              # Swift Testing; pure tests run on macOS, MapLibre tests on the simulator
Examples/MaqsDemo/              # SwiftUI app, iOS only, the package as a local reference
scripts/update-map-assets.sh    # downloads the pinned VersaTiles releases and writes Resources/
```

`Package.swift` gains the `MaqsUI` library (iOS only in practice: every MapLibre file is inside `#if canImport(MapLibre)`, UIKit and SwiftUI code inside `#if canImport(UIKit)`), the MapLibre package with the iOS condition, the `MaqsPMTiles` target, and `MaqsUITests` (on `MaqsUI` and `MaqsTestSupport`). The builder chooses file splits inside these folders.

## Public API

A sketch of the shape; names and signatures are the builder's to refine, the behaviour is not.

```swift
@MainActor @Observable public final class MaqsMap {
    public init(maqs: Maqs, configuration: MapConfiguration = .init()) throws(MapError)

    // What the map shows
    public var configuration: MapConfiguration     // style, accent, hillshade, label language, points of interest
    public var lines: [MapLine]
    public var activeLineID: MapLine.ID?           // the one line in the accent
    public var markers: [MapMarker]
    public var selectedMarkerID: MapMarker.ID?     // one selected marker at a time
    public var overlays: MapOverlays               // trails and places from installed packs
    public var selectedOverlayFeature: OverlayFeature?  // a trail drawn in the accent
    public var contentInsets: EdgeInsets           // room for the app's chrome
    public var userLocation: UserLocationMode      // .hidden, .system, .provided

    // What the map reports
    public private(set) var camera: MapCamera      // centre, zoom, heading, pitch, visible bounds
    public private(set) var connectivity: Connectivity           // .online, .offline (NWPathMonitor)
    public private(set) var uninstalledRegion: PackSummary?      // catalog region under the centre, not installed
    public private(set) var onlineTilesPaused: Bool              // the rate-limit pause
    public private(set) var credits: [MapCredit]                 // for the drawn layers
    public private(set) var lastError: MapError?
    public var onTap: ((MapTap) -> Void)?

    // Camera actions for the app's buttons
    public func follow(_ mode: FollowMode)         // .none, .position, .heading, .course
    public func resetNorth()
    public func setPitch(_ degrees: Double)
    public func show(_ coordinate: CLLocationCoordinate2D, zoom: Double?)
    public func show(_ bounds: BoundingBox)        // fits inside contentInsets
    public func provide(_ location: CLLocation)    // with .provided
}

public struct MaqsMapView: View { public init(map: MaqsMap) }
public struct MapAttributionView: View { public init(map: MaqsMap) }
```

- `MapConfiguration`: `style` (`.default`, or `.custom(light: Data, dark: Data?)`), `accent: Color`, `showsHillshade = true`, `labelLanguage: String?` (nil: the device's language when the tiles carry it, else the local `name`), `pointsOfInterest: Set<String>` (category names the style marks, below), `ambientCacheBytes` (applied before the first map loads; 50 MiB unless set *(builder's call on the default)*).
- `MapLine`: `id`, `coordinates`, `style` (`.solid`, `.hidden`), `glows` (drawn only on dark maps). The line whose id is `activeLineID` is the accent; every other solid line is grey on casing.
- `MapMarker`: `id`, `coordinate`, `content` (`.dot`, `.count(Int)`, `.image(UIImage)` such as a photo, `.symbol(UIImage, fill: Color)` for a category or pictogram, `.plate(String)` for a trail number), `label: String?`, `isHidden` (the out-of-sight style).
- `MapOverlays`: `trails: Bool`, `places: Set<String>?` (overlay `kind` values; nil is every kind). `OverlayFeature`: `region` and `featureID`, the values `MaqsData`'s `trail(region:featureID:)` and `place(region:featureID:)` take.
- `MapTap`: the coordinate and its hits, topmost first: `.marker(id)`, `.line(id)`, `.trail(OverlayFeature)`, `.place(OverlayFeature)`. Overlapping installed regions (`triveneto` and `veneto`) give one hit per region; the app keeps one.
- `MapError`: `invalidStyle(String)`, `styleFailedToLoad`, and the invalid configuration cases, with `LocalizedError` descriptions that say what to do.

`MaqsMap` is the one object per screen; `MaqsMapView` owns the `MLNMapView` through a `UIViewRepresentable` whose coordinator is not main-actor-isolated or conforms with `@preconcurrency` *(builder's call)*. Every MapLibre call happens on the main thread. Apps pass `MaqsCore`'s `BoundingBox`; `MaqsUI` adds no bbox type.

## Style assembly

`StyleAssembler` (pure, testable on macOS) takes the style JSON (the default or the app's), the online sources, the hillshade switch, the label language and the points of interest, and returns the JSON `MLNMapView(frame:styleJSON:)` gets. It never passes nil, so MapLibre never fetches its default style.

- **The contract for a style:** a vector source named `basemap` (Shortbread 1.0) and, for hillshade, a raster-dem source named `terrain`; `MaqsUI` sets their `tiles`, `bounds`, zoom range, `tileSize`, `encoding: terrarium` and `attribution`. It sets `glyphs` and `sprite` to the bundled copies (`file://` URLs into `Bundle.module`) whatever the style says, so every style works offline; an app's style uses the bundled font stacks and sprite names. A style without `basemap` is `invalidStyle`.
- **Online sources:** the first `basemap` and `terrain` entries of `Maqs.onlineSources`. With `onlineTiles` false there are none; the sources then get a placeholder template on a reserved host that the gateway never sends to the network (*(builder's call)* on the host).
- **Labels:** each `text-field` that reads `name` becomes `coalesce(name_<lang>, name)` for the configured language when the tiles carry it.
- **Points of interest:** the default style marks each POI layer with `metadata: {"maqs:poi": "<category>"}` (for example `fuel`, `alpine_hut`, `shelter`) and starts it hidden; `MaqsUI` shows the layers whose category the app lists. An app's style can use the same key.
- **Light and dark** follow the view's colour scheme: the assembler builds both, and the coordinator swaps `styleJSON` when the scheme changes. Sources keep their ids and tiles, so the swap does not reload the basemap.
- After every style load the coordinator adds the run-time sources and layers again (content, overlays, marker images) from `MaqsMap`'s state, in the design order: base map, hidden lines, casing, lines, markers, selected marker; the user location is the puck above them.

## The tile gateway

`TileGateway` is a `URLProtocol` subclass registered in MapLibre's `sessionConfiguration.protocolClasses`, together with the `User-Agent`, once, before the first `MLNMapView` exists. Its routing is a pure type (`TileRouter`), tested on macOS.

- **Which requests:** those whose URL matches the `basemap` or `terrain` template in use (host, path and `{z}/{x}/{y}`). Everything else (no other host should appear) passes through untouched.
- **Region packs first:** for a tile inside an installed region's bounds and zoom range, the region answers: the tile's bytes from `MaqsPMTiles`, or an empty 204 when it has no such tile or lacks the layer, so the region is the authority inside its bounds and nothing goes online. Basemap files serve `basemap`, terrain files serve `terrain`. When several regions cover a tile, the one with the higher maximum zoom wins, then the newer data *(builder's call on the tie-break)*. Gzip tile data is passed on as stored *(spike: MapLibre may need it inflated or a `Content-Encoding` header)*.
- **Online otherwise:** the gateway sends the request through its own `URLSession` (no `URLCache`, MapLibre's ambient cache is the cache; the app's `User-Agent`; MapLibre's conditional headers passed on; no header that disables caching) and hands the response back.
- **Base packs last:** when the online answer cannot come (`connectivity` is offline, the request fails to connect or times out, the pause is on, `onlineTiles` is false, or there is no online source), a base pack covering the tile answers it; with none, the gateway answers with a connection error, which MapLibre retries with backoff and serves from its cache meanwhile. While `connectivity` is offline the gateway goes straight to this step instead of waiting for a timeout. The gateway's request timeout is 15 s *(designer's call)*.
- **The pause:** a 429 stops every online tile request for 60 s, each further 429 doubles the pause up to 900 s, and the first success after a pause resets it, as `MaqsTerrain` does (ADR 0015). During a pause tiles go to the base-pack step, so MapLibre keeps showing cached tiles and backs off instead of retrying every 5 s; `onlineTilesPaused` is true.
- **Packs change:** `MaqsMap` observes `maqs.state.packs`; on every change it reads `installedPack(_:)` again and replaces the gateway's pack list (a lock-protected value the protocol reads from its thread). New tiles come from the new files; tiles MapLibre already holds stay until it asks again. Overlays are re-added as sources with their new URLs.
- **Offline detection:** `NWPathMonitor` sets `connectivity`, which sends the gateway straight to the base-pack step while it is offline; MapLibre's own reachability retry brings online tiles back when the network returns.
- **The download offer:** `uninstalledRegion` as settled above, computed when the camera settles, not while it moves.

**The spike, the plan's first task, on the simulator:** a `URLProtocol` in `protocolClasses` sees MapLibre's tile requests; the bytes it answers render (gzip as stored, or inflated); what MapLibre then writes to its ambient cache; the light/dark swap keeps tiles; an `MLNMapView` in the package's hostless test bundle loads its style and requests tiles (else the host-app fallback above); and the `URLProtocol` subclass compiles under Swift 6 with Xcode 26.6 (CI). If the first fails, the builder stops and reports, and the layered-sources design comes back to the owner.

## Lines, markers and overlays

- **Lines:** one GeoJSON source (`maqs-lines`), each feature carrying its style and whether it is the active one. Layers, bottom up: hidden (grey `rgba(16,22,32,.5)`/`rgba(230,237,243,.5)`, 3 pt, dash 4–5 in line widths, no casing); glow (accent, wide, `lineBlur`, dark maps only); casing (8 pt, `#FFFFFF` with a thin `#101620` edge in light, the map base `#191F28` in dark); grey lines (4 pt); the active line (accent, 5 pt). Round caps and joins. Updating `lines` replaces the source's shape, so a live track that grows by a point redraws without a style change.
- **Markers:** one GeoJSON source (`maqs-markers`) and a symbol layer whose icon is an image `MaqsUI` draws once per distinct content and registers with `setImage` (a 30 pt circle, 2 pt white ring, small shadow, the content inside; the plate red-white-red with the number). The selected marker is its own layer above, 1.25× with an accent halo. Labels are Noto Sans Bold 13 under the marker with a casing-coloured halo. Hidden markers use the hidden-line grey. Icons may overlap each other; labels give way *(builder's call on collision details)*.
- **Overlays:** per installed region, a `pmtiles://file://` source for the trails overlay and one for the places overlay, from the `role: "overlay"` file. Trails: grey 4 pt on casing, a plate with `ref` along the line, and the trail in `selectedOverlayFeature` in the accent above them. Places: round markers with a pictogram per `kind` (peak, saddle or pass, hut, shelter, settlement), drawn from SF Symbols at run time, labelled with the name, ordered by `rank_score`. Overlays exist only where a region is installed; online there are none.
- **Colours** are the design's: map base `#EEF2F7`/`#191F28`, green `#D0EEE9`/`#14282B`, water `#C1E5F6`/`#122442`, road `#FFFFFF`/`#2E343E`, location `#1C6CF7`/`#61D0FF`. They are documented in `docs/architecture.md` with the rules above, without naming their source.

## Camera, location and taps

- **Camera:** `camera` updates when the region settles, not on every frame. `follow` maps to MapLibre's tracking modes; a pan by the user drops to `.none`, and `MaqsMap` reports it. `contentInsets` keeps an item visible above the app's card; `show(_:)` uses the non-deprecated bounds call. Pitch stays within 60°. The compass, logo, attribution button and scale bar are hidden.
- **Location:** `MaqsUI` never asks for location permission (`shouldRequestAuthorizationToUseLocationServices` false); the app asks. `.system` uses MapLibre's own location manager; `.provided` installs an `MLNLocationManager` that forwards what the app passes to `provide(_:)`, so a recording app's puck shows the same fixes as its track. The puck is the location blue. Positions are never logged.
- **Taps:** a rect of 44 pt around the touch is queried on the content and overlay layers; hits come back topmost first.

## Attribution

`credits` is the union, without duplicates, of the credits for each layer being drawn: the basemap always; terrain when hillshade is on; trails and places when their overlays show. For a layer, the credits are the online source's `attribution` from `sources.json` when an online source is in use, plus the manifest's `Catalog.attribution` entries for that layer when an installed pack provides it. `MapAttributionView` shows them as a compact line that expands; each with a URL is a link; it is VoiceOver-labelled ("Map data credits"), scales with Dynamic Type and makes no layout assumption.

## Bundled assets

`scripts/update-map-assets.sh` downloads `versatiles-fonts` v3.0.0 `noto_sans.tar.gz` and `versatiles-style` v7.0.1 `styles.tar.gz` and `sprites.tar.gz`, checks their SHA-256 against pins in the script, and writes `Sources/MaqsUI/Resources/`:

- `glyphs/noto_sans_regular/` and `glyphs/noto_sans_bold/`, ranges 0–1023 and 8192–8447 (punctuation such as dashes and quotes) *(the second range is the designer's call; measured size to be recorded)*.
- `sprite/base.json`, `base.png`, `base@2x.json`, `base@2x.png`.
- `styles/default-light.json` and `styles/default-dark.json`: `muted` and `muted-dark` with their source URLs replaced by the `basemap` contract, `glyphs` and `sprite` left for the assembler, a hillshade layer added on `terrain`, every symbol layer's `text-font` set to a bundled stack, POI layers marked and hidden, and the design's colours swapped in. The transform is a small Python script run with the pipeline's `uv` environment *(builder's call on the mapping of colours to layers)*; no Node tool.
- `LICENSES.md` with the OFL text for Noto Sans and the CC0 notices for the style and sprite.

The output is committed and listed in CLAUDE.md's "never hand-edit". A test checks the committed styles name no remote URL and use only bundled stacks and ranges.

## Demo app

`Examples/MaqsDemo`: an Xcode project (iOS 18, the package as a local reference, no other dependency) *(builder's call on how the project file is produced; no generator tool)*. One map screen with a few sheets, boring on purpose:

1. **Online map** with the attribution view and the app's own buttons for follow and north.
2. **Download a region:** the catalog, `friuli-venezia-giulia` with basemap, terrain, trails and places, progress from `MaqsState`; the offer appears when the map's centre is over a region that is not installed.
3. **Airplane mode:** the same region with no network, the offline banner from `connectivity`.
4. **Trail search** (`MaqsData`): results in a list, the chosen trail in the accent through `selectedOverlayFeature`, a tap on the map opening its record.
5. **Places along a bearing** (`MaqsData` and `MaqsTerrain`): from the map's centre, a bearing slider, the sight line as lines (visible solid, hidden dashed) and the places as markers, out of sight in the hidden style.
6. **Elevation profile** (`MaqsTerrain`) along that line, in Swift Charts.

The README gives the manual steps. `swift.yml`'s simulator job builds the demo (no tests), so it cannot rot; it adds about a minute of macOS time *(designer's call)*.

## Errors and logging

`os.Logger(subsystem: "com.lucavallin.maqs", category: "ui")`: style loads and failures, pack list changes (ids only), gateway counts per minute (local, online, 204, errors) and the start and end of each pause, an invalid style with its reason. Tile coordinates are position-derived and logged `privacy: .private`, if at all; no full URL, no tile content, no position. A style that fails to load sets `lastError` and keeps the previous style. Programmer errors that MapLibre would turn into Objective-C exceptions (duplicate ids, a custom puck view of the wrong class) are made impossible by construction: `MaqsUI` owns every id.

## Tests (`Tests/MaqsUITests`, Swift Testing)

On macOS and the simulator (pure):

- `StyleAssembler`: the default styles and a minimal custom one; sources filled from a `TileSource`, bounds and zooms; glyphs and sprite set to bundle URLs; label coalescing; POI layers shown by category; `onlineTiles` false gives the reserved host; a style without `basemap` and malformed JSON are `invalidStyle`. The committed default styles name no remote URL and only bundled stacks and ranges.
- `TileRouter`: URL matching for both templates; a tile inside a region's bounds and zooms goes local, outside goes online; overlapping regions and the tie-break; a missing tile or a missing layer inside a region is 204; a base pack answers only when online cannot (offline, connection failure, timeout, pause, `onlineTiles` false); the pause sequence (429, a burst of 429s, success during and after) as in `MaqsTerrain`'s tests; `onlineTiles` false never goes online.
- `MaqsMap.init` rejects a configuration without `.basemap`; hillshade is absent without `.terrain`.
- Credits for each combination of drawn layers and sources; `uninstalledRegion` for a centre in none, one and two nested regions, under an installed, an updatable, a partial and a downloading region.

On the simulator (MapLibre):

- The `test` region installed through `MaqsCore` from the `data-ci` fixtures over `StubServer`, then the map loaded with the stub failing every request: the style loads, tiles render, and the stub sees no request while the camera is inside the region.
- Outside the region: tile requests reach the stub with the app's `User-Agent` and no cache-disabling header; a 429 sets `onlineTilesPaused` and no request follows within the pause.
- Lines, markers and overlays are present after a light/dark swap; a pack installed while the map shows adds its overlay sources.
- A tap on a fixture trail and a fixture place returns the region and feature id `MaqsData` maps to the same row.
- Marker images for each content kind have the size and ring the design gives.

Every wait on map state is on observable state with a time limit, never a sleep (CLAUDE.md, the `StubGate` lesson).

## Documentation

- ADR 0017 — `MaqsUI`: the wrapper, the tile gateway and its fallback, the dependency on `MaqsCore`, `MaqsPMTiles`, the style contract, the look, attribution, the verified MapLibre facts with sources.
- `docs/architecture.md`: `MaqsUI` in the product table; a Map section with the switching rules, the gateway, the style contract and the design rules; `MaqsPMTiles`.
- `README.md`: the `MaqsUI` product, the location permission an app must ask for, the demo's manual steps.
- `DATA_LICENSE.md`: the bundled font and style notices beside the data credits.
- `SECURITY.md`: the gateway as part of provider compliance.
- `CLAUDE.md`: where we are; the repository map; "never hand-edit" for `Sources/MaqsUI/Resources/`; things that bite: the `@preconcurrency` delegate conformance, `MLNMapView(frame:)` fetching a remote style, run-time layers lost on a style load, uncatchable exceptions on duplicate ids, MapLibre's 5 s retry on 429, `invalidateAmbientCache`, the location-permission crash.
- `swift.yml`: `paths` gain `Sources/MaqsUI/**`, `Sources/MaqsPMTiles/**` and `Examples/**`.

## Out of scope

3D terrain (MapLibre Native has none), satellite imagery, MapLibre offline packs, clustering, routing and map-matching, an online trails or places layer, a second font family or CJK glyphs, macOS rendering, the package's first tag, anything an app's chrome draws.

## Risks

- **The gateway is the one unproven piece.** If MapLibre bypasses `protocolClasses` or rejects the answers, the fallback costs seams at region edges and wasted requests inside regions. The spike runs first for that reason.
- **The ambient cache may store tiles the gateway answered locally,** taking space from online tiles; the spike measures it. They are the same data, so nothing shows wrong.
- **The pause lengths are guesses,** as for `MaqsTerrain`; VersaTiles does not publish its limit.
- **Swift 6 and an Objective-C SDK:** nothing in the headers is annotated, so the compiler will not catch off-main use of style objects; the coordinator keeps all of it on the main thread, and review checks that.
- **Overlapping regions** draw their overlays twice (identical, so unseen) and give two hits per tap.
- **Glyph ranges:** a name in a script outside the bundled ranges (beyond Latin, Greek and Cyrillic, other than CJK) draws without those letters.

## Found while designing, not fixed here

- The brief's demo step "download the test region" cannot run, since the `test` region is never published; the demo uses `friuli-venezia-giulia` (above). The brief and CLAUDE.md's test table should say so; ADR 0017 records it.
- `MaqsTerrain`'s and the map's online pauses are separate, though both talk to VersaTiles; a 429 seen by one does not pause the other.
