import CoreLocation
import Foundation
import MaqsTestSupport
import Synchronization
import Testing
@testable import MaqsTerrain

/// Cheap 256 px tiles whose values depend on the tile and the column, with a count of the tiles still alive.
private final class CountingTiles: TileProvider {
    let zoomRange = 0...12
    let tileSize = 256
    let isOnline: Bool

    private struct Made {
        weak var tile: ElevationTile?
    }

    private struct State {
        var made: [Made] = []
        var loads = 0
        var peakAlive = 0
    }

    private let state = Mutex(State())

    init(isOnline: Bool = false) {
        self.isOnline = isOnline
    }

    /// Bytes of one decoded tile.
    static let tileBytes = 256 * 256 * MemoryLayout<Float>.size

    var loads: Int { state.withLock { $0.loads } }
    /// The most tiles this provider made that were alive at once, counted each time it makes one.
    var peakAlive: Int { state.withLock { $0.peakAlive } }

    func covers(_ key: TileKey) throws -> Bool { true }

    func load(_ key: TileKey) async throws -> TileLoad {
        let base = Float(key.x % 1000) * 10 + Float(key.y % 10)
        let values = (0..<tileSize * tileSize).map { base + Float($0 % tileSize) / 64 }
        let tile = try ElevationTile(size: tileSize, elevations: values)
        state.withLock { state in
            state.made.removeAll { $0.tile == nil }
            state.made.append(Made(tile: tile))
            state.loads += 1
            state.peakAlive = max(state.peakAlive, state.made.count)
        }
        return .tile(tile)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SampleBatchingTests {
    /// One point per round in each of `tiles` distinct z12 tiles, round after round, so a tile's points are far apart
    /// in the input.
    private func scattered(tiles: Int, rounds: Int = 2) -> [CLLocationCoordinate2D] {
        (0..<rounds).flatMap { round in
            (0..<tiles).map { index in
                let pixel = 64 + round * 128
                let position = SyntheticTerrain.lonLat(key: TileKey(z: 12, x: 100 + 2 * index, y: 1457),
                                                       pixelX: pixel, pixelY: pixel, tileSize: 256)
                return CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)
            }
        }
    }

    @Test func aCallHoldsOneBatchOfTilesBeyondTheCache() async throws {
        let provider = CountingTiles()
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 4 * CountingTiles.tileBytes)
        let samples = try await terrain.elevations(at: scattered(tiles: 40))
        #expect(samples.count == 80)
        #expect(provider.loads == 40)
        // The cache keeps four tiles and a batch loads four more.
        #expect(provider.peakAlive <= 8)
    }

    @Test func batchedSamplesEqualUnbatchedOnesInInputOrder() async throws {
        let points = scattered(tiles: 40)
        let whole = try await Terrain(providers: [CountingTiles()], memoryCacheBytes: 64 << 20).elevations(at: points)
        let batched = try await Terrain(providers: [CountingTiles()], memoryCacheBytes: 4 * CountingTiles.tileBytes).elevations(at: points)
        #expect(batched == whole)
        // Every point has its own value, so a sample written to the wrong index would show.
        #expect(Set(whole.map { "\($0)" }).count == 80)
    }

    @Test func theOnlineCapHoldsAcrossBatches() async throws {
        let provider = CountingTiles(isOnline: true)
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 4 * CountingTiles.tileBytes)
        let samples = try await terrain.elevations(at: scattered(tiles: 150, rounds: 1))
        #expect(provider.loads == 128)
        #expect(samples.filter { $0 == .missing(.requestCap) }.count == 22)
    }

    @Test func aGridAndAProfileAreBatchedToo() async throws {
        let provider = CountingTiles()
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 2 * CountingTiles.tileBytes)
        let area = try TerrainArea(southWest: CLLocationCoordinate2D(latitude: 46, longitude: 11),
                                   northEast: CLLocationCoordinate2D(latitude: 46.5, longitude: 12))
        _ = try await terrain.grid(area, columns: 512, rows: 256)
        _ = try await terrain.profile(from: CLLocationCoordinate2D(latitude: 46, longitude: 11),
                                      to: CLLocationCoordinate2D(latitude: 46, longitude: 12), options: ProfileOptions(step: 100))
        #expect(provider.loads > 4)
        #expect(provider.peakAlive <= 4)
    }

    @Test func replacingArchivesBetweenBatchesLocatesTheRestAgain() async throws {
        let golden = try Golden.load()
        let known = golden.points.filter { $0.elevation != nil }
        func key(_ point: Golden.Point) -> TileKey? {
            WebMercator.position(longitude: point.lon, latitude: point.lat, zoom: 12, tileSize: 512)?.key
        }
        let first = try #require(known.first)
        let second = try #require(known.first { key($0) != key(first) })
        let expected = try #require(second.elevation)

        let gate = LoadGate()
        // 256 px tiles: a point located in them and read from the 512 px fixture would land on the wrong pixel.
        let gated = GatedTerrain(gate: gate, tileSize: 256, elevation: { _, _ in 10 })
        // One tile per batch.
        let terrain = Terrain(providers: [gated], memoryCacheBytes: 1)
        let points = [first, second].map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let call = Task { try await terrain.elevations(at: points) }
        await gate.waitUntilBlocked()
        try await terrain.setArchives([Fixtures.url("test/test-terrain.v1.pmtiles")])
        await gate.open()
        let samples = try await call.value
        #expect(samples.count == 2)
        guard case .elevation(let old) = samples[0], case .elevation(let new) = samples[1] else {
            Issue.record("expected two elevations, got \(samples)")
            return
        }
        #expect(abs(old - 10) < 1e-3)
        #expect(abs(new - expected) < 1e-6)
    }
}
