import CoreLocation
import Foundation

/// Where a coordinate falls: the tile that serves it (nil when no provider does) and the pixel inside that tile.
struct SamplePoint: Sendable {
    let tile: SourceTile?
    let pixelX: Double
    let pixelY: Double
}

/// Elevation lookups over installed archives and, where they have nothing, an online source.
public actor Terrain {
    /// Online tile fetches allowed per call.
    private static let fetchCap = 128

    private var providers: [any TileProvider]
    private let cache: TileCache

    /// Local providers come first, the one with the highest zoom first; online providers last.
    init(providers: [any TileProvider], memoryCacheBytes: Int) {
        self.providers = Self.ordered(providers)
        self.cache = TileCache(byteLimit: memoryCacheBytes)
    }

    /// Opens every archive and, when `online` is set, prepares the online source.
    ///
    /// - Throws: ``TerrainError/invalidConfiguration(_:)`` when `online` is set and the User-Agent is blank,
    ///   ``TerrainError/notTerrain(_:)`` for an archive that holds something other than terrarium tiles, and
    ///   ``PMTilesError`` for one that cannot be read.
    public init(configuration: TerrainConfiguration) throws {
        var providers: [any TileProvider] = try Self.localProviders(configuration.archives)
        if let source = configuration.online {
            guard !configuration.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TerrainError.invalidConfiguration("an online source needs an app User-Agent")
            }
            providers.append(OnlineTileProvider(
                source: source, userAgent: configuration.fullUserAgent, sessionConfiguration: configuration.urlSessionConfiguration,
                cacheDirectory: configuration.cacheDirectory, diskCacheBytes: configuration.diskCacheBytes, now: configuration.now))
        }
        self.init(providers: providers, memoryCacheBytes: configuration.memoryCacheBytes)
    }

    private static func localProviders(_ urls: [URL]) throws -> [any TileProvider] {
        try urls.map { try LocalTileProvider(url: $0) }
    }

    private static func ordered(_ providers: [any TileProvider]) -> [any TileProvider] {
        providers.enumerated().sorted { lhs, rhs in
            if lhs.element.isOnline != rhs.element.isOnline { return !lhs.element.isOnline }
            if lhs.element.zoomRange.upperBound != rhs.element.zoomRange.upperBound {
                return lhs.element.zoomRange.upperBound > rhs.element.zoomRange.upperBound
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Replaces the installed archives and keeps the online source. Clears the tile cache, whose keys carry provider indexes.
    ///
    /// Nothing changes when an archive fails to open.
    /// - Throws: the same errors as ``init(configuration:)`` for archives.
    public func setArchives(_ urls: [URL]) throws {
        let local = try Self.localProviders(urls)
        providers = Self.ordered(local + providers.filter(\.isOnline))
        cache.removeAll()
    }

    /// The first provider, in order, that covers the coordinate at its best zoom not above `zoomLimit`.
    func locate(_ coordinate: CLLocationCoordinate2D, zoomLimit: Int) throws -> SamplePoint {
        for (index, provider) in providers.enumerated() {
            let zoom = min(zoomLimit, provider.zoomRange.upperBound)
            guard zoom >= provider.zoomRange.lowerBound,
                let position = WebMercator.position(
                    longitude: coordinate.longitude, latitude: coordinate.latitude, zoom: zoom, tileSize: provider.tileSize),
                try provider.covers(position.key)
            else { continue }
            return SamplePoint(tile: SourceTile(provider: index, key: position.key), pixelX: position.pixelX, pixelY: position.pixelY)
        }
        return SamplePoint(tile: nil, pixelX: 0, pixelY: 0)
    }

    /// Loads each tile from the cache or its provider. An online fetch takes one from `budget`; at zero the tile is `.missing(.requestCap)`.
    /// Local read errors propagate; a cancelled caller throws `CancellationError`, here or from a provider it waits on.
    func load(_ tiles: Set<SourceTile>, budget: inout Int) async throws -> [SourceTile: TileLoad] {
        try Task.checkCancellation()
        var loaded: [SourceTile: TileLoad] = [:]
        var pending: [SourceTile] = []
        let ordered = tiles.sorted { ($0.provider, $0.key.z, $0.key.x, $0.key.y) < ($1.provider, $1.key.z, $1.key.x, $1.key.y) }
        for source in ordered {
            if let tile = cache.tile(for: source) {
                loaded[source] = .tile(tile)
            } else if providers[source.provider].isOnline {
                if budget > 0 {
                    budget -= 1
                    pending.append(source)
                } else {
                    loaded[source] = .missing(.requestCap)
                }
            } else {
                pending.append(source)
            }
        }
        let fetched = try await withThrowingTaskGroup(of: (SourceTile, TileLoad).self) { group in
            for source in pending {
                let provider = providers[source.provider]
                group.addTask { (source, try await provider.load(source.key)) }
            }
            var results: [(SourceTile, TileLoad)] = []
            for try await result in group { results.append(result) }
            return results
        }
        for (source, result) in fetched {
            if case .tile(let tile) = result { cache.insert(tile, for: source) }
            loaded[source] = result
        }
        return loaded
    }

    /// One sample per coordinate; each distinct tile is loaded once. `zoomLimits[i]` bounds the zoom used for `coordinates[i]`.
    func samples(at coordinates: [CLLocationCoordinate2D], zoomLimits: [Int]) async throws -> [ElevationSample] {
        guard coordinates.count == zoomLimits.count else {
            throw TerrainError.invalidInput("\(coordinates.count) coordinates with \(zoomLimits.count) zoom limits")
        }
        var points: [SamplePoint] = []
        points.reserveCapacity(coordinates.count)
        for (coordinate, limit) in zip(coordinates, zoomLimits) {
            points.append(try locate(coordinate, zoomLimit: limit))
        }
        var budget = Self.fetchCap
        let loaded = try await load(Set(points.compactMap(\.tile)), budget: &budget)
        return points.map { point in
            guard let source = point.tile, let result = loaded[source] else { return .missing(.noData) }
            switch result {
            case .tile(let tile): return .elevation(tile.elevation(pixelX: point.pixelX, pixelY: point.pixelY))
            case .missing(let reason): return .missing(reason)
            }
        }
    }

    /// Bytes held by the tile cache, for tests.
    var cachedBytes: Int { cache.byteCount }
}

extension Terrain {
    /// Grid sizes are bounded so one call cannot ask for an unbounded number of samples.
    private static let gridSides = 1...1024
    private static let metresPerDegree = 2 * Double.pi * 6_378_137 / 360

    /// The elevation at one position, from the best installed archive, or online where none has a tile.
    ///
    /// A position with no data, or whose online tile could not be fetched, is a ``ElevationSample/missing(_:)`` value, not an error.
    /// - Throws: `CancellationError` when the calling task is cancelled, or ``PMTilesError`` for an archive that turns out to be damaged.
    public func elevation(at coordinate: CLLocationCoordinate2D) async throws -> ElevationSample {
        try await elevations(at: [coordinate])[0]
    }

    /// The elevations along a route, in the order given. Each distinct tile is read once; at most 128 online tiles are fetched per call,
    /// and positions beyond that come back as ``MissingReason/requestCap``.
    /// - Throws: as ``elevation(at:)``.
    public func elevations(at coordinates: [CLLocationCoordinate2D]) async throws -> [ElevationSample] {
        try await samples(at: coordinates, zoomLimits: coordinates.map { _ in Int.max })
    }

    /// Samples the centres of a `columns` by `rows` grid over `area`.
    ///
    /// The zoom is the coarsest whose pixel is at most half a cell, so a large area costs few tiles.
    /// - Throws: ``TerrainError/invalidInput(_:)`` when `columns` or `rows` is outside 1...1024, otherwise as ``elevation(at:)``.
    public func grid(_ area: TerrainArea, columns: Int, rows: Int) async throws -> ElevationGrid {
        guard Self.gridSides.contains(columns), Self.gridSides.contains(rows) else {
            throw TerrainError.invalidInput("a grid has 1 to 1024 columns and rows, not \(columns) by \(rows)")
        }
        let latitudeSpan = area.northEast.latitude - area.southWest.latitude
        let longitudeSpan = area.northEast.longitude - area.southWest.longitude
        let centreLatitude = (area.northEast.latitude + area.southWest.latitude) / 2
        let spacing = min(
            longitudeSpan / Double(columns) * Self.metresPerDegree * cos(centreLatitude * .pi / 180),
            latitudeSpan / Double(rows) * Self.metresPerDegree)
        let zoom = (0...22).first { WebMercator.pixelSize(zoom: $0, tileSize: 512, latitude: centreLatitude) <= spacing / 2 } ?? 22
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let latitude = area.northEast.latitude - (Double(row) + 0.5) / Double(rows) * latitudeSpan
            for column in 0..<columns {
                let longitude = area.southWest.longitude + (Double(column) + 0.5) / Double(columns) * longitudeSpan
                coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
        }
        let samples = try await samples(at: coordinates, zoomLimits: coordinates.map { _ in zoom })
        return ElevationGrid(area: area, columns: columns, rows: rows, samples: samples)
    }
}
