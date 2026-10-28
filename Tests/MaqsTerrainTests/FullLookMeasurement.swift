import CoreLocation
import Foundation
import MaqsPMTiles
import MaqsTestSupport
import Synchronization
import Testing
@testable import MaqsTerrain

/// Serves the fixture tile for any key and decodes it on every call, so each cache miss costs a real ImageIO decode.
private final class DecodingProvider: TileProvider {
    let zoomRange = 0...12
    let tileSize = 512
    let isOnline = false
    private let data: Data
    private let decodeCount = Mutex(0)
    private let decodeTime = Mutex(Duration.zero)

    init(tile: Data) { data = tile }

    var decodes: Int { decodeCount.withLock { $0 } }
    /// Decode time summed over all calls, so it exceeds the wall-clock time when decodes overlap.
    var decodeSeconds: Duration { decodeTime.withLock { $0 } }

    func covers(_ key: TileKey) throws -> Bool { zoomRange.contains(key.z) }

    func load(_ key: TileKey) async throws -> TileLoad {
        let start = ContinuousClock.now
        let tile = try TerrariumDecoder.decode(data, expectedSize: tileSize)
        decodeCount.withLock { $0 += 1 }
        decodeTime.withLock { $0 += ContinuousClock.now - start }
        return .tile(tile)
    }
}

/// Prints how long a full look takes; the spec target (about 200 targets out to 100 km under 2 s on local data) is
/// recorded in ADR 0015, not asserted, because CI runners vary.
@Suite struct FullLookMeasurement {
    @Test("a full look is measured")
    func aFullLookIsMeasured() async throws {
        let archive = try PMTilesArchive(url: Fixtures.url("test/test-terrain.v1.pmtiles"))
        let tile = try #require(try archive.tile(z: 12, x: 2187, y: 1455))
        let provider = DecodingProvider(tile: tile)
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)

        let origin = CLLocationCoordinate2D(latitude: 46.10, longitude: 12.25)
        let targets = (0..<200).map { index in
            let distance = 10_000 + Double(index) * 90_000 / 199
            return SightTarget(coordinate: Geodesy.destination(from: origin, bearing: Double(index) * 1.8, distance: distance))
        }

        // The actor is free whenever the look awaits a tile, so a poller sees the cache grow.
        let peak = Mutex(0)
        let poller = Task {
            while !Task.isCancelled {
                let bytes = await terrain.cachedBytes
                peak.withLock { $0 = max($0, bytes) }
                await Task.yield()
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await terrain.visibility(of: targets, from: Observer(coordinate: origin))
        let elapsed = clock.now - start
        poller.cancel()
        let finalBytes = await terrain.cachedBytes
        peak.withLock { $0 = max($0, finalBytes) }

        print("full look: \(results.count) targets in \(elapsed), \(provider.decodes) decodes (\(provider.decodeSeconds) summed), peak cache \(peak.withLock { $0 }) bytes")
        #expect(results.count == targets.count)
        for result in results {
            switch result {
            case .visible, .hidden, .unknown, .outOfRange: break
            }
        }
    }
}
