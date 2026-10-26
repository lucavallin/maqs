import CoreLocation
import Foundation
import MaqsTestSupport
import Synchronization
import Testing
@testable import MaqsTerrain

/// A clock the test moves by hand.
private final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}

/// Counts the requests a route has answered.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

@Suite(.timeLimit(.minutes(1))) struct OnlineTileProviderTests {
    private static let template = "https://tiles.example.org/{z}/{x}/{y}"
    private static let userAgent = "Test/1 Maqs/0.1.0"
    /// The fixture's eastern z12 tile, served online by the stub.
    private static let key = TileKey(z: 12, x: 2187, y: 1455)

    private let server = StubServer()

    private static func url(of key: TileKey) throws -> URL {
        try #require(URL(string: "https://tiles.example.org/\(key.z)/\(key.x)/\(key.y)"))
    }

    private func provider(clock: TestClock = TestClock(), tileSize: Int = 512, configuration: URLSessionConfiguration? = nil,
                          cacheDirectory: URL? = nil) throws -> OnlineTileProvider {
        let source = try OnlineTerrainSource(tiles: Self.template, format: "webp", tileSize: tileSize, minZoom: 0, maxZoom: 12)
        return OnlineTileProvider(source: source, userAgent: Self.userAgent, sessionConfiguration: configuration ?? server.configuration,
                                  cacheDirectory: cacheDirectory, diskCacheBytes: 1 << 20, now: { clock.now })
    }

    private static func fixtureTile() throws -> Data {
        let archive = try PMTilesArchive(url: Fixtures.url("test/test-terrain.v1.pmtiles"))
        return try #require(try archive.tile(z: key.z, x: key.x, y: key.y))
    }

    /// The centre of a 512 px tile.
    private static func centre(of key: TileKey) -> CLLocationCoordinate2D {
        let place = SyntheticTerrain.lonLat(key: key, pixelX: 256, pixelY: 256, tileSize: 512)
        return CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }

    private static func sample(_ terrain: Terrain, at coordinate: CLLocationCoordinate2D) async throws -> ElevationSample {
        try await terrain.samples(at: [coordinate], zoomLimits: [12])[0]
    }

    private static func isElevation(_ sample: ElevationSample) -> Bool {
        if case .elevation = sample { true } else { false }
    }

    /// Waits until `condition` holds, polling rather than sleeping; the cancellation check lets the suite's time limit
    /// end the wait should the condition never come true.
    private static func waitUntil(_ condition: () async -> Bool) async throws {
        while !(await condition()) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    @Test func onlineSamplesEqualTheLocalOnes() async throws {
        server.route(try Self.url(of: Self.key), body: try Self.fixtureTile())
        let golden = try Golden.load()
        let coordinates = golden.points
            .filter { WebMercator.position(longitude: $0.lon, latitude: $0.lat, zoom: 12, tileSize: 512)?.key == Self.key }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        #expect(coordinates.count > 10)
        let limits = coordinates.map { _ in 12 }
        let online = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        let local = Terrain(providers: [try LocalTileProvider(url: Fixtures.url("test/test-terrain.v1.pmtiles"))], memoryCacheBytes: 64 << 20)
        let onlineSamples = try await online.samples(at: coordinates, zoomLimits: limits)
        let localSamples = try await local.samples(at: coordinates, zoomLimits: limits)
        #expect(onlineSamples == localSamples)
        #expect(onlineSamples.allSatisfy(Self.isElevation))
        #expect(server.requests.count == 1)
    }

    @Test func everyRequestCarriesTheUserAgentAndNoCacheHeader() async throws {
        server.route(try Self.url(of: Self.key), body: try Self.fixtureTile())
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        let other = TileKey(z: 12, x: 2186, y: 1455)
        _ = try await terrain.samples(at: [Self.centre(of: Self.key), Self.centre(of: other)], zoomLimits: [12, 12])
        #expect(server.requests.count == 2)
        for request in server.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == nil)
            #expect(request.value(forHTTPHeaderField: "Pragma") == nil)
            #expect(request.cachePolicy == .useProtocolCachePolicy)
        }
    }

    @Test func theGivenConfigurationIsCopiedNotChanged() throws {
        let configuration = server.configuration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let originalCache = configuration.urlCache
        let directory = try TemporaryDirectory()
        let provider = try provider(configuration: configuration, cacheDirectory: directory.url)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache === originalCache)
        let used = provider.session.configuration
        #expect(used.requestCachePolicy == .useProtocolCachePolicy)
        #expect(used.urlCache?.diskCapacity == 1 << 20)
        #expect(used.urlCache?.memoryCapacity == 0)
        #expect(used.httpAdditionalHeaders?["X-Maqs-Stub"] as? String == server.id)
    }

    @Test func a404IsNoData() async throws {
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(terrain, at: Self.centre(of: Self.key)) == .missing(.noData))
        #expect(server.requests.count == 1)
    }

    @Test func a500IsNetworkFailure() async throws {
        server.route(try Self.url(of: Self.key), status: 500, body: Data("busy".utf8))
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(terrain, at: Self.centre(of: Self.key)) == .missing(.networkFailure))
    }

    @Test func aTransportErrorIsNetworkFailure() async throws {
        server.route(try Self.url(of: Self.key)) { _ in StubResponse(transportError: .notConnectedToInternet) }
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(terrain, at: Self.centre(of: Self.key)) == .missing(.networkFailure))
    }

    @Test func garbageIsNetworkFailure() async throws {
        server.route(try Self.url(of: Self.key), body: Data("not a tile".utf8))
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(terrain, at: Self.centre(of: Self.key)) == .missing(.networkFailure))
    }

    @Test func aTileOfAnotherSizeIsNetworkFailure() async throws {
        server.route(try Self.url(of: Self.key), body: try Self.fixtureTile())
        let terrain = Terrain(providers: [try provider(tileSize: 256)], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(terrain, at: Self.centre(of: Self.key)) == .missing(.networkFailure))
    }

    @Test func a429StartsTheCoolDown() async throws {
        let tile = try Self.fixtureTile()
        let counter = Counter()
        server.route(try Self.url(of: Self.key)) { _ in
            counter.next() == 1 ? StubResponse(status: 429) : StubResponse(status: 200, body: tile)
        }
        let clock = TestClock()
        let terrain = Terrain(providers: [try provider(clock: clock)], memoryCacheBytes: 64 << 20)
        let point = Self.centre(of: Self.key)
        #expect(try await Self.sample(terrain, at: point) == .missing(.rateLimited))
        #expect(server.requests.count == 1)
        clock.advance(by: .seconds(30))
        #expect(try await Self.sample(terrain, at: point) == .missing(.rateLimited))
        #expect(server.requests.count == 1)
        clock.advance(by: .seconds(31))
        #expect(Self.isElevation(try await Self.sample(terrain, at: point)))
        #expect(server.requests.count == 2)
    }

    /// A 200 for a request sent before the 429 came back says nothing about the server's limit now.
    @Test func aTileFromTheSameBurstDoesNotUndoTheDoubling() async throws {
        let limited = TileKey(z: 12, x: 2186, y: 1455)
        let limitedGate = StubGate()
        let tileGate = StubGate()
        defer {
            limitedGate.release()
            tileGate.release()
        }
        server.route(try Self.url(of: limited)) { _ in StubResponse(status: 429, gate: limitedGate) }
        let tile = try Self.fixtureTile()
        server.route(try Self.url(of: Self.key)) { _ in StubResponse(status: 200, body: tile, gate: tileGate) }
        let clock = TestClock()
        let provider = try provider(clock: clock)
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let points = [Self.centre(of: limited), Self.centre(of: Self.key)]
        let burst = Task { try await terrain.samples(at: points, zoomLimits: [12, 12]) }
        // Both requests are out before either answer: one burst.
        try await Self.waitUntil { server.requests.count >= 2 }
        limitedGate.release()
        // The 429 is settled once its flight has ended, so the tile let through next arrives during the pause.
        try await Self.waitUntil { !(await provider.isFetching(limited)) }
        tileGate.release()
        let samples = try await burst.value
        #expect(server.requests.count == 2)
        #expect(samples[0] == .missing(.rateLimited))
        #expect(Self.isElevation(samples[1]))
        clock.advance(by: .seconds(61))
        #expect(try await Self.sample(terrain, at: Self.centre(of: limited)) == .missing(.rateLimited))
        #expect(server.requests.count == 3)
        // That second 429 starts a 120 s pause, not 60 s.
        clock.advance(by: .seconds(119))
        #expect(try await Self.sample(terrain, at: Self.centre(of: limited)) == .missing(.rateLimited))
        #expect(server.requests.count == 3)
        clock.advance(by: .seconds(2))
        _ = try await Self.sample(terrain, at: Self.centre(of: limited))
        #expect(server.requests.count == 4)
    }

    @Test func requestsQueuedBehindA429AreNotSent() async throws {
        let keys = (0..<12).map { TileKey(z: 12, x: 2000 + $0, y: 1400) }
        for key in keys { server.route(try Self.url(of: key), status: 429, body: Data()) }
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        let samples = try await terrain.samples(at: keys.map(Self.centre), zoomLimits: keys.map { _ in 12 })
        #expect(samples.allSatisfy { $0 == .missing(.rateLimited) })
        // At most the four already past the limiter when the first 429 arrived.
        #expect(server.requests.count <= 4)
    }

    @Test func oneRequestForATileManyCallersWant() async throws {
        let gate = StubGate()
        defer { gate.release() }
        let tile = try Self.fixtureTile()
        server.route(try Self.url(of: Self.key)) { _ in StubResponse(status: 200, body: tile, gate: gate) }
        let provider = try provider()
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let point = Self.centre(of: Self.key)
        async let first = Self.sample(terrain, at: point)
        async let second = Self.sample(terrain, at: point)
        // Both callers wait on the one fetch before its answer is let through.
        try await Self.waitUntil { await provider.waiters(for: Self.key) >= 2 }
        gate.release()
        let (one, two) = try await (first, second)
        #expect(Self.isElevation(one))
        #expect(one == two)
        #expect(server.requests.count == 1)
    }

    /// Review Focus 5.
    @Test func aCancelledWaiterLeavesTheFetchForTheOthers() async throws {
        let gate = StubGate()
        defer { gate.release() }
        let tile = try Self.fixtureTile()
        server.route(try Self.url(of: Self.key)) { _ in StubResponse(status: 200, body: tile, gate: gate) }
        let provider = try provider()
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let point = Self.centre(of: Self.key)
        let callers = (0..<3).map { _ in Task { try await Self.sample(terrain, at: point) } }
        // All three wait on one fetch whose request is out and held by the gate.
        try await Self.waitUntil { await provider.waiters(for: Self.key) >= 3 && !server.requests.isEmpty }
        callers[1].cancel()
        await #expect(throws: CancellationError.self) { try await callers[1].value }
        gate.release()
        let first = try await callers[0].value
        let third = try await callers[2].value
        #expect(Self.isElevation(first))
        #expect(third == first)
        #expect(server.requests.count == 1)
        #expect(await provider.waiters(for: Self.key) == 0)
        // A fresh Terrain has an empty cache, so the provider is asked again and must not find a stuck fetch.
        let later = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        #expect(try await Self.sample(later, at: point) == first)
        #expect(server.requests.count <= 2)
    }

    /// Ruling R7: a queued fetch whose callers have all left sends no request, and a later caller starts afresh.
    @Test func aTileNobodyWaitsForAnyMoreIsNotRequested() async throws {
        // Four tiles whose answers the gate holds keep every limiter slot until the test releases them.
        let gate = StubGate()
        defer { gate.release() }
        let blockers = (0..<4).map { TileKey(z: 12, x: 2000 + $0, y: 1400) }
        for key in blockers { server.route(try Self.url(of: key)) { _ in StubResponse(status: 404, gate: gate) } }
        let tileURL = try Self.url(of: Self.key)
        server.route(tileURL, body: try Self.fixtureTile())
        let provider = try provider()
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let holding = Task { try await terrain.samples(at: blockers.map(Self.centre), zoomLimits: blockers.map { _ in 12 }) }
        try await Self.waitUntil { server.requests.count >= 4 }
        let abandoned = Task { try await Self.sample(terrain, at: Self.centre(of: Self.key)) }
        try await Self.waitUntil { await provider.waiters(for: Self.key) >= 1 }
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        gate.release()
        _ = try await holding.value
        // The slots are free now; the abandoned fetch gets its turn and ends without a request.
        try await Self.waitUntil { !(await provider.isFetching(Self.key)) }
        #expect(!server.requests.contains { $0.url == tileURL })
        // A caller arriving afterwards starts a fresh flight and gets the tile.
        #expect(Self.isElevation(try await Self.sample(terrain, at: Self.centre(of: Self.key))))
        #expect(server.requests.filter { $0.url == tileURL }.count == 1)
    }

    @Test func thePerCallCapIs128() async throws {
        let terrain = Terrain(providers: [try provider()], memoryCacheBytes: 64 << 20)
        let coordinates = (0..<129).map { Self.centre(of: TileKey(z: 12, x: 2000 + $0, y: 1400)) }
        let samples = try await terrain.samples(at: coordinates, zoomLimits: coordinates.map { _ in 12 })
        #expect(server.requests.count == 128)
        #expect(samples.filter { $0 == .missing(.noData) }.count == 128)
        #expect(samples.filter { $0 == .missing(.requestCap) }.count == 1)
    }
}
