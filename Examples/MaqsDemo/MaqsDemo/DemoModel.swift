import CoreLocation
import Foundation
import MaqsCore
import MaqsData
import MaqsTerrain
import MaqsUI
import Observation

/// The demo's state: one `Maqs`, one map, the `MaqsData` and `MaqsTerrain` readers over the installed files, and the
/// sheet on screen.
@MainActor @Observable
final class DemoModel {
    /// Where the map opens: the box of `friuli-venezia-giulia` in `data-2026-10`, the region the README's walk installs.
    static let startArea = BoundingBox(minLon: 12.3214, minLat: 45.5809, maxLon: 13.9187, maxLat: 46.648)

    /// The overlays the map shows outside the sight line: every trail and every place of the installed regions.
    static let overlays = MapOverlays(trails: true, places: nil)

    let maqs: Maqs
    let map: MaqsMap
    let location: LocationPermission
    /// Trail search and records over the installed trails files.
    let trails: Trails
    /// Places along a bearing and place records over the installed places files.
    let places: Places
    /// Elevations from the installed terrain files and, elsewhere, online; `nil` until ``start()`` made it.
    private(set) var terrain: Terrain?
    /// The sight line the map shows, with its profile and places; `nil` when none is shown.
    private(set) var sightLine: SightLine?
    /// The sheet on screen, if any.
    var sheet: DemoSheet?
    /// How much of the map's bottom a sheet that keeps the map in use covers, in points; 0 for none.
    var sheetHeight: CGFloat = 0
    /// The last problem that is not a pack's own state, for the banner.
    var message: String?
    @ObservationIgnored private var started = false

    /// `MaqsDemo/<version> (iOS)`: the free tile provider asks every app to name itself.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "MaqsDemo/\(version) (iOS)"
    }

    /// Makes the one `Maqs` and the map, before any map view exists.
    init() throws {
        var configuration = MaqsConfiguration(layers: [.basemap, .terrain, .trails, .places], userAgent: Self.userAgent)
        configuration.backgroundSessionIdentifier = "com.lucavallin.maqs.demo.downloads"
        // Launched with `-onlineTiles NO`, the package hands out no online source: no tile request leaves the device.
        // The argument arrives as the string "NO", which `bool(forKey:)` reads and a cast to Bool does not.
        let defaults = UserDefaults.standard
        configuration.onlineTiles = defaults.object(forKey: "onlineTiles") == nil || defaults.bool(forKey: "onlineTiles")
        maqs = try Maqs(configuration: configuration)
        map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(accent: .orange))
        location = LocationPermission(manager: CLLocationManager())
        trails = try Trails(files: [])
        places = try Places(files: [])
        map.overlays = Self.overlays
        map.onTap = { [weak self] tap in self?.handle(tap) }
    }

    // MARK: Start

    /// Opens the readers over the installed files, then refreshes the online sources and the catalog.
    func start() async {
        guard !started else { return }
        started = true
        do {
            try await maqs.refreshOnlineSources()
        } catch {
            // The cached or bundled copy stays in use.
            logger.error("sources.json not refreshed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let online = try await maqs.onlineSources?.terrain.first.map { source in
                try OnlineTerrainSource(tiles: source.tiles, format: source.format, tileSize: source.tileSize ?? 512,
                                        minZoom: source.minZoom, maxZoom: source.maxZoom)
            }
            terrain = try Terrain(configuration: TerrainConfiguration(archives: [], online: online, userAgent: Self.userAgent))
        } catch {
            report("Elevations are not available", error)
        }
        await reloadFiles()
        await refreshCatalog(policy: .ifStale)
    }

    /// Loads the catalog; a failure shows in the regions sheet through `MaqsState.lastRefreshError`.
    func refreshCatalog(policy: RefreshPolicy) async {
        do {
            try await maqs.refreshCatalog(policy: policy)
        } catch {
            logger.error("catalog not refreshed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Packs

    /// Downloads `pack`, then hands the readers the new files. The pack's state shows the progress and any failure.
    func install(_ pack: PackID) {
        Task {
            do {
                try await maqs.install(pack)
            } catch {
                logger.error("install of \(String(describing: pack), privacy: .public) ended: \(error.localizedDescription, privacy: .public)")
            }
            await reloadFiles()
        }
    }

    /// Stops the download of `pack`; what was installed before stays.
    func cancelInstall(_ pack: PackID) {
        Task { await maqs.cancelInstall(pack) }
    }

    /// Deletes `pack`, then hands the readers the files that are left.
    func remove(_ pack: PackID) {
        Task {
            do {
                try await maqs.remove(pack)
            } catch {
                report("The region could not be removed", error)
            }
            await reloadFiles()
        }
    }

    /// Hands every reader the files of the installed packs. Called at start and after every install or removal,
    /// because SQLite cannot read a file that was replaced or deleted while open.
    func reloadFiles() async {
        var trailFiles: [URL] = []
        var placeFiles: [URL] = []
        var archives: [URL] = []
        for id in maqs.state.packs.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            guard let pack = await maqs.installedPack(id) else { continue }
            // The SQLite files; trails and places also list their map overlay, with the role "overlay".
            trailFiles += (pack.files[.trails] ?? []).filter { $0.role == nil }.map(\.url)
            placeFiles += (pack.files[.places] ?? []).filter { $0.role == nil }.map(\.url)
            archives += [Layer.terrain, .terrainHD].flatMap { pack.files[$0] ?? [] }.map(\.url)
        }
        // Each reader keeps its previous files when the new ones fail to open, so one failure leaves the others current.
        do {
            try await trails.setFiles(trailFiles)
        } catch {
            report("The trails files could not be opened", error)
        }
        do {
            try await places.setFiles(placeFiles)
        } catch {
            report("The places files could not be opened", error)
        }
        do {
            try await terrain?.setArchives(archives)
        } catch {
            report("The terrain files could not be opened", error)
        }
        logger.info("readers: \(trailFiles.count, privacy: .public) trails, \(placeFiles.count, privacy: .public) places, \(archives.count, privacy: .public) terrain files")
    }

    // MARK: Location

    /// The location button: asks for permission the first time, then shows the location and steps through
    /// following the position, following the heading, and not following.
    func locationButtonTapped() {
        switch location.status {
        case .notDetermined:
            location.request { [weak self] in self?.showLocation() }
        case .authorizedWhenInUse, .authorizedAlways:
            guard map.userLocation != .hidden else {
                showLocation()
                return
            }
            switch map.followMode {
            case .none: map.follow(.position)
            case .position: map.follow(.heading)
            case .heading, .course: map.follow(.none)
            }
        default:
            message = "Location is off for Maqs Demo. Allow it in Settings to see where you are."
        }
    }

    private func showLocation() {
        map.userLocation = .system
        map.follow(.position)
    }

    // MARK: Trails and places

    /// Trails matching `text`, nearest to the map's centre first; empty when nothing matches or the search fails.
    func searchTrails(_ text: String) async -> [TrailSummary] {
        do {
            return try await trails.search(text, near: map.camera.center, limit: 50)
        } catch {
            report("The trail search failed", error)
            return []
        }
    }

    /// Draws `trail` in the accent and shows all of it.
    func select(_ trail: TrailSummary) {
        map.selectedOverlayFeature = OverlayFeature(region: trail.region, featureID: trail.featureID)
        if let area = trail.area {
            // `show` fits the box edge to edge; a margin keeps the trail's ends off the edges of the view.
            let margin = 0.15
            let width = (area.maxLongitude - area.minLongitude) * margin
            let height = (area.maxLatitude - area.minLatitude) * margin
            map.show(BoundingBox(minLon: area.minLongitude - width, minLat: area.minLatitude - height,
                                 maxLon: area.maxLongitude + width, maxLat: area.maxLatitude + height))
        }
        sheet = nil
    }

    /// What a tap on the map does: in the sight line it selects a marker or a line; elsewhere it opens the record of
    /// the trail or place under it. A tap on nothing clears the selection.
    private func handle(_ tap: MapTap) {
        logger.info("tap: \(tap.hits.count, privacy: .public) hits")
        if case .sightLine? = sheet {
            // Markers and lines lie above the overlays, so the first of them is the one the finger was on.
            switch tap.hits.first(where: { Self.overlayFeature($0) == nil }) {
            case .marker(let id)?: map.selectedMarkerID = id
            case .line(let id)?: map.activeLineID = id
            default:
                map.selectedMarkerID = nil
                map.activeLineID = nil
            }
            return
        }
        guard let feature = tap.hits.lazy.compactMap(Self.overlayFeature).first else {
            map.selectedOverlayFeature = nil
            return
        }
        Task { await open(feature) }
    }

    private static func overlayFeature(_ hit: MapHit) -> (feature: OverlayFeature, isTrail: Bool)? {
        switch hit {
        case .trail(let feature): (feature, true)
        case .place(let feature): (feature, false)
        case .marker, .line: nil
        }
    }

    private func open(_ hit: (feature: OverlayFeature, isTrail: Bool)) async {
        do {
            if hit.isTrail {
                map.selectedOverlayFeature = hit.feature
                if let trail = try await trails.trail(region: hit.feature.region, featureID: hit.feature.featureID) {
                    sheet = .trail(trail)
                }
            } else if let place = try await places.place(region: hit.feature.region, featureID: hit.feature.featureID) {
                sheet = .place(place)
            }
        } catch {
            report("The record could not be read", error)
        }
    }

    // MARK: Sight line

    /// Computes the sight line from `origin` along `bearing` and draws it: the stretches in sight solid, those out of
    /// sight dashed, and the places near the line as markers, muted when they cannot be seen.
    func showSightLine(from origin: CLLocationCoordinate2D, bearing: Double) async {
        guard let terrain else {
            message = "Elevations are not available yet."
            return
        }
        do {
            let line = try await SightLine.compute(from: origin, bearing: bearing, terrain: terrain, places: places)
            sightLine = line
            // The line and its places replace the overlays, whose grey trails would hide the line's solid stretches.
            map.overlays = MapOverlays(trails: false, places: [])
            map.selectedMarkerID = nil
            map.activeLineID = nil
            map.lines = line.mapLines
            map.markers = line.mapMarkers
            let seen = line.samples.filter(\.inSight).count
            logger.info("sight line: \(line.mapLines.count, privacy: .public) stretches, \(seen, privacy: .public) of \(line.samples.count, privacy: .public) samples in sight, \(line.sights.filter(\.visible).count, privacy: .public) of \(line.sights.count, privacy: .public) places")
        } catch is CancellationError {
            // A newer bearing replaced this one; its result is the one to draw.
            return
        } catch {
            report("The sight line could not be computed", error)
        }
    }

    /// Fits the circle the sight line can reach around `origin`, so every bearing stays in view.
    func frameSightLine(around origin: CLLocationCoordinate2D) {
        let latitude = SightLine.length / 111_320
        let longitude = SightLine.length / (111_320 * max(cos(origin.latitude * .pi / 180), 0.01))
        map.show(BoundingBox(minLon: origin.longitude - longitude, minLat: origin.latitude - latitude,
                             maxLon: origin.longitude + longitude, maxLat: origin.latitude + latitude))
    }

    /// Takes the sight line off the map.
    func clearSightLine() {
        sightLine = nil
        map.overlays = Self.overlays
        map.lines = []
        map.markers = []
        map.activeLineID = nil
        map.selectedMarkerID = nil
    }

    // MARK: Messages

    private func report(_ summary: String, _ error: any Error) {
        logger.error("\(summary, privacy: .public): \(error.localizedDescription, privacy: .public)")
        message = "\(summary): \(error.localizedDescription)"
    }
}
