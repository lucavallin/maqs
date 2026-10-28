#if canImport(MapLibre)
import CoreLocation
import Foundation
import MaqsCore
import MaqsPMTiles
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
///
/// The online sources are read with the packs: a refreshed `sources.json` takes effect at the next pack change or in
/// a new `MaqsMap`. While a map exists, the main actor wakes every 5 s to read the gateway's pause and counters.
///
/// The camera actions, such as ``show(_:zoom:)`` and ``resetNorth()``, animate the view that shows the map and do
/// nothing before one does; only the mode of ``follow(_:)`` is kept for it.
@MainActor @Observable public final class MaqsMap {
    /// The style, accent, hillshade, label language and points of interest. A change rebuilds the style.
    public var configuration: MapConfiguration {
        didSet { if configuration != oldValue { rebuildStyles() } }
    }

    /// The lines the app draws, such as routes or tracks. Replacing them redraws the lines without a style change, so
    /// a track that grows by a point is cheap to show.
    public var lines: [MapLine] = [] {
        didSet { if lines != oldValue { coordinator?.showLines() } }
    }

    /// The one line drawn in the accent; every other solid line is grey. An id no line has marks none.
    public var activeLineID: MapLine.ID? {
        didSet { if activeLineID != oldValue { coordinator?.showLines() } }
    }

    /// The markers the app draws. Markers that look the same share one image, drawn when the first of them appears.
    public var markers: [MapMarker] = [] {
        didSet { coordinator?.showMarkers() }
    }

    /// The one selected marker, drawn larger with an accent halo above the others. An id no marker has selects none.
    public var selectedMarkerID: MapMarker.ID? {
        didSet { if selectedMarkerID != oldValue { coordinator?.showMarkers() } }
    }

    /// The trails and places of the installed regions that the map draws.
    public var overlays: MapOverlays {
        didSet { if overlays != oldValue { rebuildStyles() } }
    }

    /// The trail drawn in the accent above the others, in the region the feature names; `nil` for none. Pass a trail:
    /// a ``MapHit/trail(_:)`` hit's feature, or a trail's region and feature id from `MaqsData`. Places count their ids
    /// apart, so a place's feature would name some other trail. The trails overlay must be shown (``overlays``) for the
    /// trail to be seen.
    public var selectedOverlayFeature: OverlayFeature? {
        didSet { if selectedOverlayFeature != oldValue { coordinator?.showSelectedOverlayFeature() } }
    }

    /// Called on the main actor for every single tap on the map, with what the tap touched: the app's markers and
    /// lines and the overlays' trails and places in the 44-point square around the touch, topmost first, each once. A
    /// tap on nothing has no hits. A double tap zooms the map and is not reported.
    @ObservationIgnored public var onTap: ((MapTap) -> Void)?

    /// Room the app's chrome takes at the map's edges, such as a card along the bottom. The map's centre, the followed
    /// location and ``show(_:)`` keep to the rest of the view. The map adds no safe area of its own: count
    /// the status bar or the home indicator in when the map runs under them. A change keeps the coordinate at the
    /// centre, which moves to the middle of what is left.
    public var contentInsets = EdgeInsets() {
        didSet { if contentInsets != oldValue { coordinator?.showContentInsets() } }
    }

    /// Whether and from where the map shows the user's location, in the location blue. The map never asks for
    /// permission. With ``UserLocationMode/system`` the location shows once the app has permission, and again when the
    /// user allows it after denying it; with ``UserLocationMode/provided`` it is what the app passes to ``provide(_:)``.
    /// Hiding the location stops following it.
    public var userLocation: UserLocationMode = .hidden {
        didSet {
            guard userLocation != oldValue else { return }
            coordinator?.showUserLocation()
            if userLocation == .hidden && followMode != .none { followMode = .none }
        }
    }

    /// How the camera follows the user's location now. It drops to ``FollowMode/none`` when the user pans the map, the
    /// app shows a place or the location is hidden, and from heading or course to ``FollowMode/position`` when the map
    /// turns north or the user rotates it.
    public private(set) var followMode: FollowMode = .none

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
    /// again when the pause ends. It is read from the gateway every 5 s, so it can trail the pause by up to that.
    public private(set) var onlineTilesPaused = false

    /// The last thing that went wrong: an app style that is not valid, or a style MapLibre failed to load. The map
    /// keeps drawing from the last style that built and still follows the packs. `nil` again once the app's style
    /// builds.
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
    @ObservationIgnored private var installedPacks: [InstalledPack] = []
    @ObservationIgnored private var content = InstalledContent.none
    /// The catalog last seen: a region's box comes from it.
    @ObservationIgnored private var catalogSeen: Catalog?
    /// The base styles of the last build that succeeded; the style is built from them while the app's is invalid.
    @ObservationIgnored private var lastGoodBases: (light: Data, dark: Data)?
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
        let catalogChanged = catalog != catalogSeen
        catalogSeen = catalog
        let snapshot = packs.mapValues { state -> InstalledPack? in
            if case .installed(let pack) = state { return pack }
            return nil
        }
        if snapshot != packSnapshot {
            packSnapshot = snapshot
            readPacks(packs.keys.sorted { Self.describe($0) < Self.describe($1) })
        } else if catalogChanged && packsRead {
            refreshContent()
        }
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
        let rebuild = !packsRead || sources != self.sources
        installedPacks = packs
        self.sources = sources
        packsRead = true
        refreshContent(rebuild: rebuild)
    }

    /// Works out the installed content from the last packs read and the current catalog, and rebuilds the style when
    /// it changed or `rebuild` asks for it.
    private func refreshContent(rebuild: Bool = false) {
        let content = MapInputs.content(packs: installedPacks, layers: maqs.configuration.layers,
                                        catalog: maqs.state.catalog, archives: archiveInfos)
        guard rebuild || content != self.content else { return }
        if content != self.content || !packsRead {
            let ids = installedPacks.map { Self.describe($0.id) }.joined(separator: ", ")
            logger.info("map packs: \(ids.isEmpty ? "none" : ids, privacy: .public)")
        }
        self.content = content
        if routingTable != content.table { routingTable = content.table }
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

    /// Hands the gateway the table and the templates, then assembles the light and dark styles. The gateway's templates
    /// come only from what the whole `Maqs` says (the online sources and the configured layers), never from one map's
    /// hillshade switch, and the gateway keeps claiming every template set it had before: no tile URL a style of this
    /// process names reaches the network unclaimed, whatever another map or a change of sources did.
    private func rebuildStyles() {
        guard packsRead else { return }
        GatewayState.shared.setTable(content.table)
        let templates = MapInputs.templates(sources: sources, layers: maqs.configuration.layers,
                                            showsHillshade: configuration.showsHillshade)
        configureGateway(templates)
        do {
            let bases = try baseStyles()
            let built = try build(from: bases, templates)
            lastGoodBases = bases
            lastError = nil
            publish(built)
        } catch {
            logger.error("map style not built: \(String(describing: error), privacy: .public)")
            lastError = error
            // The packs are still followed, from the last base style that built: a removed pack's overlay must not
            // stay in the style pointing at a deleted file.
            guard let lastGoodBases else { return }
            do {
                publish(try build(from: lastGoodBases, templates))
            } catch {
                logger.error("map style not built from the last good base: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func publish(_ built: MapStyles) {
        if built != styles { styles = built }
    }

    /// The light and dark base styles the configuration names.
    private func baseStyles() throws(MapError) -> (light: Data, dark: Data) {
        switch configuration.style {
        case .default: (try BundledAssets.defaultStyle(dark: false), try BundledAssets.defaultStyle(dark: true))
        case .custom(let light, let dark): (light, dark ?? light)
        }
    }

    private func build(from bases: (light: Data, dark: Data), _ templates: MapTemplates) throws(MapError) -> MapStyles {
        MapStyles(light: try assemble(bases.light, templates, dark: false),
                  dark: try assemble(bases.dark, templates, dark: true))
    }

    private func assemble(_ base: Data, _ templates: MapTemplates, dark: Bool) throws(MapError) -> String {
        let inputs = StyleInputs(
            basemap: templates.basemap, terrain: templates.terrain, glyphs: BundledAssets.glyphsTemplate,
            sprite: BundledAssets.spriteURL, labelLanguage: configuration.labelLanguage ?? Self.deviceLanguage,
            pointsOfInterest: configuration.pointsOfInterest, overlays: content.overlays,
            visiblePlaceKinds: overlays.places, showsTrails: overlays.trails,
            content: ContentStyle(dark: dark, accentHex: Self.hex(accentColor(dark: dark))))
        return try StyleAssembler.assemble(base, inputs)
    }

    private func configureGateway(_ templates: MapTemplates) {
        let key = GatewayKey(templates: templates.gateway, onlineAllowed: templates.onlineAllowed)
        guard key != gatewayKey else { return }
        gatewayKey = key
        GatewayState.shared.configure(GatewayConfiguration(
            templates: key.templates, onlineAllowed: key.onlineAllowed, userAgent: maqs.configuration.fullUserAgent,
            sessionConfiguration: seams.gatewaySession))
        logger.info("map tile gateway configured: online \(key.onlineAllowed ? "allowed" : "off", privacy: .public), terrain \(key.templates.terrain == nil ? "off" : "on", privacy: .public)")
    }

    // MARK: Camera actions

    /// Makes the camera follow the user's location, or stop with ``FollowMode/none``; ``followMode`` says what it
    /// does. Following needs the location shown: while ``userLocation`` is ``UserLocationMode/hidden`` only `.none`
    /// does anything. A mode chosen before a ``MaqsMapView`` shows the map applies when it does.
    public func follow(_ mode: FollowMode) {
        guard mode == .none || userLocation != .hidden else {
            logger.debug("map follow ignored: the user's location is hidden")
            return
        }
        if let coordinator {
            coordinator.follow(mode)
        } else if mode != followMode {
            followMode = mode
        }
    }

    /// Turns the map to north. Following the heading or the course becomes following the position.
    public func resetNorth() {
        coordinator?.resetNorth()
    }

    /// Tilts the map `degrees` from looking straight down, kept within 0…60, at the same zoom. Not a number does
    /// nothing.
    public func setPitch(_ degrees: Double) {
        guard !degrees.isNaN else {
            logger.debug("map pitch ignored: not a number")
            return
        }
        coordinator?.setPitch(min(max(degrees, 0), 60))
    }

    /// Centres the map on `coordinate` at `zoom`, or at the current zoom when it is `nil`, and stops following. A
    /// coordinate off the earth or a zoom that is not finite does nothing.
    public func show(_ coordinate: CLLocationCoordinate2D, zoom: Double?) {
        guard CLLocationCoordinate2DIsValid(coordinate), zoom?.isFinite ?? true else {
            logger.debug("map show ignored: the coordinate or the zoom is not valid")
            return
        }
        coordinator?.show(coordinate, zoom: zoom)
    }

    /// Fits `bounds` in the view inside ``contentInsets`` and stops following. An inverted box or one off the earth
    /// does nothing.
    public func show(_ bounds: BoundingBox) {
        let southWest = CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon)
        let northEast = CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)
        guard CLLocationCoordinate2DIsValid(southWest), CLLocationCoordinate2DIsValid(northEast),
              bounds.minLat <= bounds.maxLat, bounds.minLon <= bounds.maxLon else {
            logger.debug("map show ignored: the box is not valid")
            return
        }
        coordinator?.show(southWest: southWest, northEast: northEast)
    }

    /// Moves the user's location to `location` while ``userLocation`` is ``UserLocationMode/provided``, and is
    /// ignored otherwise. Pass each fix the app records, so the map shows the same location as the app's data. A
    /// location off the earth is dropped.
    public func provide(_ location: CLLocation) {
        guard userLocation == .provided else { return }
        guard CLLocationCoordinate2DIsValid(location.coordinate) else {
            logger.debug("map dropped a provided location that is not valid")
            return
        }
        coordinator?.provide(location)
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

    /// MapLibre changed how it follows the location: asked to, or because the user moved the map.
    func followModeDidChange(_ mode: FollowMode) {
        if mode != followMode { followMode = mode }
    }

    /// The accent resolved for the scheme: the marker images are drawn in it, and the style's lines get its hex value.
    func accentColor(dark: Bool) -> UIColor {
        UIColor(configuration.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
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

    /// A resolved colour as `#RRGGBB`.
    private static func hex(_ color: UIColor) -> String {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
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
