#if canImport(MapLibre)
import CoreLocation
import Foundation
import MaqsCore
import MaqsPMTiles
import Observation
import SwiftUI
import UIKit

/// What a map needs from its surroundings, replaced in tests: the base of the gateway's session, where connectivity
/// comes from and how often the gateway's pause and counters are read.
struct MapSeams {
    var gatewaySession: URLSessionConfiguration = .ephemeral
    var connectivity: () -> AsyncStream<Connectivity> = { Connectivity.updates() }
    var gatewayReadInterval: Duration = .seconds(5)
}

/// The two assembled styles; the view shows the one of its colour scheme.
struct MapStyles: Equatable {
    var light: String
    var dark: String

    func json(dark: Bool) -> String { dark ? self.dark : light }
}

/// The map of one screen: what the app wants drawn and what the map reports. Show it with ``MaqsMapView``.
///
/// Inside an installed region the map draws from the downloaded files, even with signal; elsewhere it streams the
/// `sources.json` tiles, and with no network it shows what it cached from earlier viewing. A pack installed or removed
/// while the map shows changes what it draws, with no new view. Only the layers the app configured in `Maqs` are drawn
/// or requested: the basemap always, hillshade with `.terrain`, the overlays with `.trails` and `.places`.
///
/// Every map of a process shares one tile gateway, so all of them use the same ``Maqs``. Create the first `MaqsMap`
/// before any map view exists in the process: its initialiser puts the gateway in front of MapLibre's network, which
/// MapLibre reads once, when its first view is created. A map view created earlier, even by other code, leaves every
/// tile of the process outside the gateway.
@MainActor @Observable public final class MaqsMap {
    /// The style, accent, hillshade, label language and points of interest. A change rebuilds the style.
    public var configuration: MapConfiguration {
        didSet { if configuration != oldValue { rebuildStyles() } }
    }

    /// The trails and places of the installed regions that the map draws.
    public var overlays: MapOverlays {
        didSet { if overlays != oldValue { rebuildStyles() } }
    }

    /// Where the map looks, updated when the camera settles, not while it moves.
    public private(set) var camera = MapCamera(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 0, heading: 0, pitch: 0,
        visibleBounds: BoundingBox(minLon: -180, minLat: -85.051_128_78, maxLon: 180, maxLat: 85.051_128_78))

    /// Whether the device has a network path. While offline the map asks for nothing.
    public private(set) var connectivity: Connectivity = .online

    /// The smallest catalog region under the map's centre that is not installed and not being installed, for the app
    /// to offer as a download; `nil` when an installed region covers the centre or no catalog region does.
    public private(set) var uninstalledRegion: PackSummary?

    /// Whether online tiles are paused because the provider answered 429. The map then draws what it has and asks
    /// again when the pause ends.
    public private(set) var onlineTilesPaused = false

    /// The last thing that went wrong: an app style that is not valid, or a style MapLibre failed to load. The map
    /// keeps the style it had. `nil` again after the next style is built.
    public private(set) var lastError: MapError?

    // MARK: Read by the view and by tests

    /// The assembled styles for the current packs and configuration; `nil` until the packs have been read once.
    private(set) var styles: MapStyles?
    /// What the gateway routes: the installed regions and base packs.
    private(set) var routingTable = InstalledContent.none.table
    /// The gateway's counters as of its last read, every ``MapSeams/gatewayReadInterval``.
    private(set) var gatewayCounters = GatewayCounters()
    /// The coordinator of the view showing this map, which owns the MapLibre view.
    @ObservationIgnored private(set) weak var coordinator: MaqsMapView.Coordinator?

    // MARK: State

    @ObservationIgnored private let maqs: Maqs
    @ObservationIgnored private let seams: MapSeams
    /// The online sources and installed content of the last pack read; the style is rebuilt from these.
    @ObservationIgnored private var sources: OnlineSources?
    @ObservationIgnored private var content = InstalledContent.none
    @ObservationIgnored private var packsRead = false
    /// What the packs said last time, with transient states (queued, downloading, failed) folded together, so download
    /// progress does not read the packs again.
    @ObservationIgnored private var packSnapshot: [PackID: InstalledPack?]?
    @ObservationIgnored private var archiveInfos: [URL: ArchiveInfo] = [:]
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var gatewayKey: GatewayKey?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?

    /// What `GatewayState.configure` was last given, to configure it again only when something changed.
    private struct GatewayKey: Equatable {
        var templates: TileTemplates
        var onlineAllowed: Bool
    }

    /// Creates the map for `maqs`, observing its packs and the device's connectivity.
    ///
    /// - Throws: ``MapError/basemapNotConfigured`` when `maqs` was not configured with `.basemap`.
    public convenience init(maqs: Maqs, configuration: MapConfiguration = MapConfiguration()) throws(MapError) {
        try self.init(maqs: maqs, configuration: configuration, seams: MapSeams())
    }

    init(maqs: Maqs, configuration: MapConfiguration, seams: MapSeams) throws(MapError) {
        guard maqs.configuration.layers.contains(.basemap) else { throw .basemapNotConfigured }
        self.maqs = maqs
        self.configuration = configuration
        self.overlays = MapOverlays()
        self.seams = seams
        MapNetwork.prepare(userAgent: maqs.configuration.fullUserAgent, ambientCacheBytes: configuration.ambientCacheBytes)
        start()
    }

    isolated deinit {
        connectivityTask?.cancel()
        readTask?.cancel()
        heartbeatTask?.cancel()
    }

    // MARK: Start

    /// Connectivity first: the gateway must know whether the device is offline before the first tile is asked for, so
    /// the packs, and with them the style, are read only after the first connectivity report.
    private func start() {
        let updates = seams.connectivity()
        connectivityTask = Task { [weak self] in
            for await value in updates {
                guard let self else { return }
                self.setConnectivity(value)
            }
        }
        let interval = seams.gatewayReadInterval
        heartbeatTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastLog = clock.now
            var logged = GatewayCounters()
            while true {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.readGateway()
                if clock.now - lastLog >= .seconds(60) {
                    lastLog = clock.now
                    logged = Self.logCounters(since: logged)
                }
            }
        }
    }

    private func setConnectivity(_ value: Connectivity) {
        if value != connectivity {
            logger.info("map connectivity: \(value == .online ? "online" : "offline", privacy: .public)")
            connectivity = value
        }
        GatewayState.shared.setOffline(value == .offline)
        if !observing {
            observing = true
            observePacks()
        }
    }

    // MARK: Packs

    /// Reads the packs and the catalog, and arms an observation that calls this again after their next change.
    private func observePacks() {
        let state = maqs.state
        let (packs, catalog) = withObservationTracking {
            (state.packs, state.catalog)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePacks() }
        }
        updateOffer(catalog: catalog, packs: packs)
        let snapshot = packs.mapValues { state -> InstalledPack? in
            if case .installed(let pack) = state { return pack }
            return nil
        }
        guard snapshot != packSnapshot else { return }
        packSnapshot = snapshot
        readPacks(packs.keys.sorted { Self.describe($0) < Self.describe($1) })
    }

    /// Reads every pack's installed files (a pack being updated keeps its old files until the update ends), the headers
    /// of archives not read before, and the online sources; a newer read supersedes this one.
    private func readPacks(_ ids: [PackID]) {
        readGeneration += 1
        let generation = readGeneration
        let maqs = maqs
        let known = archiveInfos
        readTask = Task { [weak self] in
            let sources = await maqs.onlineSources
            var packs: [InstalledPack] = []
            for id in ids {
                if let pack = await maqs.installedPack(id) { packs.append(pack) }
            }
            let infos = await Self.readArchives(MapInputs.tileArchives(of: packs).filter { known[$0] == nil })
            guard let self, self.readGeneration == generation else { return }
            self.packsChanged(packs, sources: sources, infos: infos)
        }
    }

    private func packsChanged(_ packs: [InstalledPack], sources: OnlineSources?, infos: [URL: ArchiveInfo]) {
        let listed = Set(MapInputs.tileArchives(of: packs))
        archiveInfos = archiveInfos.merging(infos) { _, new in new }.filter { listed.contains($0.key) }
        self.sources = sources
        let content = MapInputs.content(packs: packs, layers: maqs.configuration.layers, catalog: maqs.state.catalog,
                                        archives: archiveInfos)
        if content != self.content || !packsRead {
            let ids = packs.map { Self.describe($0.id) }.joined(separator: ", ")
            logger.info("map packs: \(ids.isEmpty ? "none" : ids, privacy: .public)")
        }
        self.content = content
        if routingTable != content.table { routingTable = content.table }
        packsRead = true
        rebuildStyles()
    }

    /// The header of each archive, read off the main actor. An archive that cannot be opened is logged and left out:
    /// its region then answers that layer empty.
    @concurrent private nonisolated static func readArchives(_ urls: [URL]) async -> [URL: ArchiveInfo] {
        var infos: [URL: ArchiveInfo] = [:]
        for url in urls {
            do {
                let header = try PMTilesArchive(url: url).header
                infos[url] = ArchiveInfo(
                    minZoom: header.minZoom, maxZoom: header.maxZoom,
                    bounds: BoundingBox(minLon: header.bounds.west, minLat: header.bounds.south,
                                        maxLon: header.bounds.east, maxLat: header.bounds.north))
            } catch {
                logger.error("map archive \(url.lastPathComponent, privacy: .public) cannot be read (\(String(describing: error), privacy: .public)): its tiles are answered empty")
            }
        }
        return infos
    }

    private func updateOffer(catalog: Catalog?, packs: [PackID: PackState]) {
        let offer = RegionOffer.region(at: camera.center, catalog: catalog, packs: packs)
        if offer != uninstalledRegion { uninstalledRegion = offer }
    }

    // MARK: Style

    /// Assembles the light and dark styles from the current inputs and hands the gateway what they need, the table
    /// first. The gateway's templates change only together with a style that names them: a tile request that no
    /// longer matches the templates is failed, so a style that fails to build keeps the templates it was built with.
    private func rebuildStyles() {
        guard packsRead else { return }
        GatewayState.shared.setTable(content.table)
        let templates = MapInputs.templates(sources: sources, layers: maqs.configuration.layers,
                                            showsHillshade: configuration.showsHillshade)
        let built: MapStyles
        do {
            built = MapStyles(light: try assemble(templates, dark: false), dark: try assemble(templates, dark: true))
        } catch {
            logger.error("map style not built: \(String(describing: error), privacy: .public)")
            lastError = error
            return
        }
        configureGateway(templates)
        lastError = nil
        if built != styles { styles = built }
    }

    private func assemble(_ templates: MapTemplates, dark: Bool) throws(MapError) -> String {
        let base: Data = switch configuration.style {
        case .default: try BundledAssets.defaultStyle(dark: dark)
        case .custom(let light, let darkStyle): dark ? darkStyle ?? light : light
        }
        let inputs = StyleInputs(
            basemap: templates.basemap, terrain: templates.terrain, glyphs: BundledAssets.glyphsTemplate,
            sprite: BundledAssets.spriteURL, labelLanguage: configuration.labelLanguage ?? Self.deviceLanguage,
            pointsOfInterest: configuration.pointsOfInterest, overlays: content.overlays,
            visiblePlaceKinds: overlays.places, showsTrails: overlays.trails,
            content: ContentStyle(dark: dark, accentHex: Self.hex(configuration.accent, dark: dark)))
        return try StyleAssembler.assemble(base, inputs)
    }

    private func configureGateway(_ templates: MapTemplates) {
        let key = GatewayKey(templates: templates.gateway, onlineAllowed: templates.onlineAllowed)
        guard key != gatewayKey else { return }
        gatewayKey = key
        GatewayState.shared.configure(GatewayConfiguration(
            templates: key.templates, onlineAllowed: key.onlineAllowed, userAgent: maqs.configuration.fullUserAgent,
            sessionConfiguration: seams.gatewaySession))
        logger.info("map tile gateway configured: online \(key.onlineAllowed ? "allowed" : "off", privacy: .public), hillshade \(key.templates.terrain == nil ? "off" : "on", privacy: .public)")
    }

    // MARK: Called by the view

    func attach(_ coordinator: MaqsMapView.Coordinator) {
        self.coordinator = coordinator
    }

    func detach(_ coordinator: MaqsMapView.Coordinator) {
        if self.coordinator === coordinator { self.coordinator = nil }
    }

    func styleDidLoad() {
        logger.info("map style loaded")
    }

    func styleDidFail(_ error: any Error) {
        logger.error("map style failed to load: \(error.localizedDescription, privacy: .public)")
        lastError = .styleFailedToLoad
    }

    func cameraDidSettle(_ camera: MapCamera) {
        if camera != self.camera { self.camera = camera }
        updateOffer(catalog: maqs.state.catalog, packs: maqs.state.packs)
    }

    // MARK: The gateway's pause and counters

    private func readGateway() {
        let paused = GatewayState.shared.isPaused
        if paused != onlineTilesPaused { onlineTilesPaused = paused }
        let counters = GatewayState.shared.counters
        if counters != gatewayCounters { gatewayCounters = counters }
    }

    /// Logs what the gateway answered since `previous`, when it answered anything, and returns the current counts.
    private static func logCounters(since previous: GatewayCounters) -> GatewayCounters {
        let now = GatewayState.shared.counters
        let local = now.local - previous.local, empty = now.empty - previous.empty
        let online = now.online - previous.online, base = now.base - previous.base
        let failed = now.failed - previous.failed, passed = now.passedThrough - previous.passedThrough
        if [local, empty, online, base, failed, passed].contains(where: { $0 != 0 }) {
            logger.info("map tiles in the last minute: local \(local, privacy: .public), empty \(empty, privacy: .public), online \(online, privacy: .public), base \(base, privacy: .public), failed \(failed, privacy: .public), stale template \(passed, privacy: .public)")
        }
        return now
    }

    // MARK: Helpers

    private static var deviceLanguage: String? {
        Locale.current.language.languageCode?.identifier
    }

    /// The accent as `#RRGGBB`, resolved for the scheme.
    private static func hex(_ color: Color, dark: Bool) -> String {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let bytes = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    private static func describe(_ pack: PackID) -> String {
        switch pack {
        case .region(let id): id
        case .base(let id): "base \(id)"
        }
    }
}
#endif
