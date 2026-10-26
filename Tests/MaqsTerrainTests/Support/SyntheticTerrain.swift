import Foundation
import Synchronization
@testable import MaqsTerrain

/// A `TileProvider` that builds tiles from an elevation function, with gaps and a log of every load.
final class SyntheticTerrain: TileProvider {
    let zoomRange: ClosedRange<Int>
    let tileSize: Int
    let isOnline: Bool
    private let elevation: @Sendable (Double, Double) -> Double
    private let gap: @Sendable (TileKey) -> Bool
    private let log = Mutex<[TileKey]>([])

    /// `elevation` takes longitude and latitude; a tile for which `gap` is true is not covered.
    init(tileSize: Int = 256, zoomRange: ClosedRange<Int> = 0...14, isOnline: Bool = false,
         elevation: @escaping @Sendable (Double, Double) -> Double, gap: @escaping @Sendable (TileKey) -> Bool = { _ in false }) {
        self.tileSize = tileSize
        self.zoomRange = zoomRange
        self.isOnline = isOnline
        self.elevation = elevation
        self.gap = gap
    }

    /// Every tile key passed to `load`, in call order.
    var loads: [TileKey] { log.withLock { $0 } }

    /// Longitude and latitude of the centre of a pixel, by the inverse of `WebMercator.position`.
    static func lonLat(key: TileKey, pixelX: Int, pixelY: Int, tileSize: Int) -> (lon: Double, lat: Double) {
        let count = Double(1 << key.z)
        let fx = (Double(key.x) + (Double(pixelX) + 0.5) / Double(tileSize)) / count
        let fy = (Double(key.y) + (Double(pixelY) + 0.5) / Double(tileSize)) / count
        return (fx * 360 - 180, atan(sinh(.pi * (1 - 2 * fy))) * 180 / .pi)
    }

    func covers(_ key: TileKey) throws -> Bool {
        zoomRange.contains(key.z) && !gap(key)
    }

    func load(_ key: TileKey) async throws -> TileLoad {
        log.withLock { $0.append(key) }
        var values = [Float](repeating: 0, count: tileSize * tileSize)
        for row in 0..<tileSize {
            for column in 0..<tileSize {
                let position = Self.lonLat(key: key, pixelX: column, pixelY: row, tileSize: tileSize)
                values[row * tileSize + column] = Float(elevation(position.lon, position.lat))
            }
        }
        return .tile(try ElevationTile(size: tileSize, elevations: values))
    }
}
