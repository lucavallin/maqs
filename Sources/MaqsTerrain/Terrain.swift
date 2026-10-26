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

    private let providers: [any TileProvider]
    private let cache: TileCache

    /// Local providers come first, the one with the highest zoom first; online providers last.
    init(providers: [any TileProvider], memoryCacheBytes: Int) {
        self.providers = providers.enumerated().sorted { lhs, rhs in
            if lhs.element.isOnline != rhs.element.isOnline { return !lhs.element.isOnline }
            if lhs.element.zoomRange.upperBound != rhs.element.zoomRange.upperBound {
                return lhs.element.zoomRange.upperBound > rhs.element.zoomRange.upperBound
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        self.cache = TileCache(byteLimit: memoryCacheBytes)
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
