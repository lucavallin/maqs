import CoreLocation
import Foundation

/// Where a coordinate falls: the tile that serves it (nil when no provider does) and the pixel inside that tile.
struct SamplePoint: Sendable {
    let tile: SourceTile?
    let pixelX: Double
    let pixelY: Double
}

/// Elevation lookups over installed archives and, where they have nothing, an online source.
///
/// Create one `Terrain` and share it across the app. The provider etiquette belongs to an instance: each has its own
/// 429 cool-down, its own limit of four requests at once and its own HTTP cache over the one cache directory, so a
/// second instance doubles the requests a free server sees and does not pause when the first one does.
public actor Terrain {
    /// Online tile fetches allowed per call.
    static let fetchCap = 128

    private(set) var providers: [any TileProvider]
    private let cache: TileCache
    /// The cache bound; every call sizes its batches of tiles by it.
    let memoryCacheBytes: Int
    /// Bumped by `setArchives`; a load that started under an older value does not cache its tiles, whose provider indexes are stale.
    private var generation = 0

    /// Local providers come first, the one with the highest zoom first; online providers last.
    init(providers: [any TileProvider], memoryCacheBytes: Int) {
        self.providers = Self.ordered(providers)
        self.cache = TileCache(byteLimit: memoryCacheBytes)
        self.memoryCacheBytes = memoryCacheBytes
    }

    /// Opens every archive and, when `online` is set, prepares the online source.
    ///
    /// An archive that fails to open is logged with its file name before the error is thrown.
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

    /// Opens every archive. One that fails is logged with its file name and the error case, and the error is thrown.
    private static func localProviders(_ urls: [URL]) throws -> [any TileProvider] {
        try urls.map { url throws -> any TileProvider in
            do {
                return try LocalTileProvider(url: url)
            } catch {
                logger.error("terrain archive \(url.lastPathComponent, privacy: .public) did not open: \(Self.errorCase(error), privacy: .public)")
                throw error
            }
        }
    }

    /// The error's case for the log, without the URL `notTerrain` carries: it holds the app's container path.
    private static func errorCase(_ error: any Error) -> String {
        if case TerrainError.notTerrain = error { return "notTerrain" }
        return String(describing: error)
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
        generation += 1
        cache.removeAll()
    }

    /// The first provider, in order, that covers the coordinate at its best zoom not above `zoomLimit`.
    /// Only when none does, a provider whose minimum zoom is above the limit is tried at that minimum zoom, in the same order.
    func locate(_ coordinate: CLLocationCoordinate2D, zoomLimit: Int) throws -> SamplePoint {
        var tooFine: [(index: Int, provider: any TileProvider)] = []
        for (index, provider) in providers.enumerated() {
            let zoom = min(zoomLimit, provider.zoomRange.upperBound)
            guard zoom >= provider.zoomRange.lowerBound else {
                tooFine.append((index, provider))
                continue
            }
            if let point = try point(coordinate, zoom: zoom, provider: provider, index: index) { return point }
        }
        for (index, provider) in tooFine {
            if let point = try point(coordinate, zoom: provider.zoomRange.lowerBound, provider: provider, index: index) { return point }
        }
        return SamplePoint(tile: nil, pixelX: 0, pixelY: 0)
    }

    private func point(_ coordinate: CLLocationCoordinate2D, zoom: Int, provider: any TileProvider, index: Int) throws -> SamplePoint? {
        guard let position = WebMercator.position(
                longitude: coordinate.longitude, latitude: coordinate.latitude, zoom: zoom, tileSize: provider.tileSize),
            try provider.covers(position.key)
        else { return nil }
        return SamplePoint(tile: SourceTile(provider: index, key: position.key), pixelX: position.pixelX, pixelY: position.pixelY)
    }

    /// Loads each tile from the cache or its provider. An online fetch takes one from `budget`; at zero the tile is `.missing(.requestCap)`.
    /// Local read errors propagate; a cancelled caller throws `CancellationError`, here or from a provider it waits on.
    func load(_ tiles: Set<SourceTile>, budget: inout Int) async throws -> [SourceTile: TileLoad] {
        try Task.checkCancellation()
        let startedUnder = generation
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
            if case .tile(let tile) = result, generation == startedUnder { cache.insert(tile, for: source) }
            loaded[source] = result
        }
        return loaded
    }

    /// Tiles one batch of a call loads at once: as many decoded tiles of the largest tile size as fit the cache bound, at
    /// least one. A call samples each batch before it loads the next, so it holds at most this many tiles beyond the cache.
    var tilesPerBatch: Int {
        let side = providers.map(\.tileSize).max() ?? 512
        return max(1, memoryCacheBytes / (side * side * MemoryLayout<Float>.size))
    }

    /// One sample per coordinate, in input order. `zoomLimits[i]` bounds the zoom used for `coordinates[i]`.
    ///
    /// The points are grouped by tile and the tiles loaded in batches of `tilesPerBatch`, in the order the input first
    /// needs them, so neighbouring points of a route share a batch and each distinct tile is loaded once. Every batch
    /// draws on the one online budget of the call.
    func samples(at coordinates: [CLLocationCoordinate2D], zoomLimits: [Int]) async throws -> [ElevationSample] {
        guard coordinates.count == zoomLimits.count else {
            throw TerrainError.invalidInput("\(coordinates.count) coordinates with \(zoomLimits.count) zoom limits")
        }
        var results = [ElevationSample](repeating: .missing(.noData), count: coordinates.count)
        var budget = Self.fetchCap
        var unsampled = Array(coordinates.indices)
        while !unsampled.isEmpty {
            let locatedUnder = generation
            var tiles: [SourceTile] = []
            var pointsByTile: [SourceTile: [(index: Int, point: SamplePoint)]] = [:]
            for index in unsampled {
                let point = try locate(coordinates[index], zoomLimit: zoomLimits[index])
                // A point no provider covers keeps its `.noData`.
                guard let tile = point.tile else { continue }
                if pointsByTile[tile] == nil { tiles.append(tile) }
                pointsByTile[tile, default: []].append((index, point))
            }
            unsampled = []
            let batchSize = tilesPerBatch
            var next = 0
            while next < tiles.count {
                let batch = tiles[next..<min(next + batchSize, tiles.count)]
                let loaded = try await load(Set(batch), budget: &budget)
                for tile in batch {
                    for (index, point) in pointsByTile[tile] ?? [] { results[index] = Self.resolve(point, loaded) }
                }
                next = batch.endIndex
                // setArchives may have run while the batch loaded; the points still to sample were located with the old
                // providers, whose indexes are stale, so they are located again.
                if generation != locatedUnder, next < tiles.count {
                    unsampled = tiles[next...].flatMap { pointsByTile[$0]?.map(\.index) ?? [] }.sorted()
                    break
                }
            }
        }
        return results
    }

    /// The sample at a located point, from the tiles a batch loaded.
    static func resolve(_ point: SamplePoint, _ loaded: [SourceTile: TileLoad]) -> ElevationSample {
        guard let source = point.tile, let result = loaded[source] else { return .missing(.noData) }
        switch result {
        case .tile(let tile): return .elevation(tile.elevation(pixelX: point.pixelX, pixelY: point.pixelY))
        case .missing(let reason): return .missing(reason)
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
    ///
    /// Tiles are decoded in batches that fit ``TerrainConfiguration/memoryCacheBytes``, and each batch is sampled before the
    /// next is read, so a long list of scattered positions holds at most one batch of tiles beyond the cache.
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

    /// A profile is bounded so one call cannot ask for an unbounded number of samples.
    private static let maxProfilePoints = 100_000

    /// Samples the terrain along the great circle from `from` to `to`.
    ///
    /// Samples start at distance 0 and are `options.step` apart (by default one tile pixel of the zoom used at that distance) up to and including the end.
    /// Tiles are read at the zoom `options.bands` gives for the distance, so far samples use coarser tiles.
    /// - Throws: ``TerrainError/invalidInput(_:)`` for a non-finite endpoint, a `step` under 1 m, an ``EarthModel`` whose radius is not above 0
    ///   or whose refraction is not finite, or a profile of more than 100,000 points, otherwise as ``elevation(at:)``.
    public func profile(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, options: ProfileOptions = ProfileOptions()) async throws -> ElevationProfile {
        guard [from.latitude, from.longitude, to.latitude, to.longitude].allSatisfy(\.isFinite),
              abs(from.latitude) <= 90, abs(to.latitude) <= 90 else {
            throw TerrainError.invalidInput("profile endpoints must be finite latitudes within 90 degrees")
        }
        if let step = options.step, !(step >= 1) {
            throw TerrainError.invalidInput("a profile step is at least 1 metre, not \(step)")
        }
        try options.earth.validate()
        let total = Geodesy.distance(from, to)
        var distances: [Double] = [0]
        var distance = 0.0
        while true {
            let zoom = options.bands.zoom(atDistance: distance)
            distance += options.step ?? WebMercator.pixelSize(zoom: zoom, tileSize: 512, latitude: from.latitude)
            guard distance < total else { break }
            guard distances.count < Self.maxProfilePoints else {
                throw TerrainError.invalidInput("a profile has at most \(Self.maxProfilePoints) points; use a larger step or a shorter line")
            }
            distances.append(distance)
        }
        if total > 0 { distances.append(total) }
        let coordinates = distances.map { total > 0 ? Geodesy.intermediate(from: from, to: to, fraction: $0 / total) : from }
        let samples = try await samples(at: coordinates, zoomLimits: distances.map { options.bands.zoom(atDistance: $0) })
        var points: [ProfilePoint] = []
        points.reserveCapacity(distances.count)
        for index in distances.indices {
            let apparent: Double?
            if case .elevation(let metres) = samples[index] {
                apparent = metres - options.earth.drop(atDistance: distances[index])
            } else {
                apparent = nil
            }
            points.append(ProfilePoint(distance: distances[index], coordinate: coordinates[index], ground: samples[index], apparentElevation: apparent))
        }
        return ElevationProfile(points: points)
    }
}
