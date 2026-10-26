import CoreLocation
import Foundation
import MaqsTestSupport
import Synchronization
import Testing
@testable import MaqsTerrain

/// A provider whose loads wait until the test lets them go.
private final class GatedProvider: TileProvider {
    let zoomRange = 0...12
    let tileSize = 256
    let isOnline = false
    private let started = Mutex(false)
    private let release = Mutex<CheckedContinuation<Void, Never>?>(nil)

    var hasStarted: Bool { started.withLock { $0 } }

    func covers(_ key: TileKey) throws -> Bool { true }

    func load(_ key: TileKey) async throws -> TileLoad {
        await withCheckedContinuation { continuation in
            release.withLock { $0 = continuation }
            started.withLock { $0 = true }
        }
        return .tile(try ElevationTile(size: tileSize, elevations: [Float](repeating: 10, count: tileSize * tileSize)))
    }

    func open() { release.withLock { $0?.resume(); $0 = nil } }
}

@Suite(.timeLimit(.minutes(1))) struct ElevationTests {
    private static let fixture = "test/test-terrain.v1.pmtiles"

    private func terrain(archives: [URL]? = nil) throws -> Terrain {
        try Terrain(configuration: TerrainConfiguration(archives: archives ?? [Fixtures.url(Self.fixture)]))
    }

    private func coordinate(_ point: Golden.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    @Test func elevationMatchesTheGoldenPoints() async throws {
        let golden = try Golden.load()
        let terrain = try terrain()
        for point in golden.points {
            let sample = try await terrain.elevation(at: coordinate(point))
            switch (point.elevation, sample) {
            case (nil, .missing(.noData)): break
            case (let expected?, .elevation(let value)): #expect(abs(value - expected) < 1e-6)
            default: Issue.record("lon \(point.lon) lat \(point.lat): expected \(String(describing: point.elevation)), got \(sample)")
            }
        }
    }

    @Test func aRouteKeepsItsOrder() async throws {
        let golden = try Golden.load()
        let points = Array(golden.points.prefix(40).reversed())
        let samples = try await terrain().elevations(at: points.map(coordinate))
        #expect(samples.count == points.count)
        for (point, sample) in zip(points, samples) {
            switch (point.elevation, sample) {
            case (nil, .missing(.noData)): break
            case (let expected?, .elevation(let value)): #expect(abs(value - expected) < 1e-6)
            default: Issue.record("lon \(point.lon) lat \(point.lat): unexpected \(sample)")
            }
        }
    }

    @Test func noArchivesMeansNoDataThenSetArchivesBringsValues() async throws {
        let terrain = try terrain(archives: [])
        let place = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)
        #expect(try await terrain.elevation(at: place) == .missing(.noData))
        try await terrain.setArchives([Fixtures.url(Self.fixture)])
        guard case .elevation = try await terrain.elevation(at: place) else {
            Issue.record("expected an elevation after setArchives")
            return
        }
    }

    @Test func setArchivesDuringALoadDoesNotCacheTheOldTile() async throws {
        let gated = GatedProvider()
        let terrain = Terrain(providers: [gated], memoryCacheBytes: 64 << 20)
        let place = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)
        let inFlight = Task { try await terrain.elevation(at: place) }
        // The time limit cancels only this task, so the loop must check for it or a hang stalls the whole run.
        while !gated.hasStarted {
            try Task.checkCancellation()
            await Task.yield()
        }
        try await terrain.setArchives([Fixtures.url(Self.fixture)])
        gated.open()
        #expect(try await inFlight.value == .elevation(10))
        #expect(await terrain.cachedBytes == 0)
        guard case .elevation(let value) = try await terrain.elevation(at: place) else {
            Issue.record("expected an elevation from the new archive")
            return
        }
        #expect(value != 10)
    }
}
