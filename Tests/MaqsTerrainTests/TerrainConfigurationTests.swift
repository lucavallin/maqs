import CoreLocation
import Foundation
import MaqsTestSupport
import OSLog
import Testing
@testable import MaqsTerrain

@Suite(.timeLimit(.minutes(1))) struct TerrainConfigurationTests {
    private static let template = "https://tiles.example.org/{z}/{x}/{y}"
    private static let fixture = "test/test-terrain.v1.pmtiles"

    private func source() throws -> OnlineTerrainSource {
        try OnlineTerrainSource(tiles: Self.template, format: "webp", tileSize: 512, minZoom: 0, maxZoom: 12)
    }

    @Test(arguments: ["", "  "])
    func aBlankUserAgentWithAnOnlineSourceIsRejected(userAgent: String) throws {
        let configuration = TerrainConfiguration(archives: [], online: try source(), userAgent: userAgent)
        #expect {
            _ = try Terrain(configuration: configuration)
        } throws: { error in
            guard case .invalidConfiguration = error as? TerrainError else { return false }
            return true
        }
    }

    @Test func aBlankUserAgentWithoutOneIsFine() throws {
        _ = try Terrain(configuration: TerrainConfiguration(archives: [Fixtures.url(Self.fixture)]))
    }

    @Test func aBasemapArchiveIsNotTerrain() throws {
        let basemap = try Fixtures.url("test/test-basemap.v1.pmtiles")
        #expect(throws: TerrainError.notTerrain(basemap)) {
            _ = try Terrain(configuration: TerrainConfiguration(archives: [basemap]))
        }
    }

    @Test func aCorruptArchiveThrowsAPMTilesError() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "corrupt.pmtiles")
        try Data(repeating: 7, count: 300).write(to: url)
        #expect(throws: PMTilesError.self) {
            _ = try Terrain(configuration: TerrainConfiguration(archives: [url]))
        }
    }

    @Test func setArchivesClearsTheCache() async throws {
        let terrain = try Terrain(configuration: TerrainConfiguration(archives: [Fixtures.url(Self.fixture)]))
        _ = try await terrain.elevation(at: CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25))
        #expect(await terrain.cachedBytes > 0)
        try await terrain.setArchives([Fixtures.url(Self.fixture)])
        #expect(await terrain.cachedBytes == 0)
    }

    @Test func theUserAgentIsTheAppStringPlusMaqs() async throws {
        let server = StubServer()
        let directory = try TemporaryDirectory()
        var configuration = TerrainConfiguration(archives: [], online: try source(), userAgent: "Test/1")
        configuration.urlSessionConfiguration = server.configuration
        configuration.cacheDirectory = directory.url
        let terrain = try Terrain(configuration: configuration)
        _ = try await terrain.elevation(at: CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test/1 Maqs/0.1.0")
    }

    // MARK: Logging

    /// This process's `terrain` log messages since `start` that contain `needle`.
    ///
    /// The log store lags the call that logged: it is polled until a matching line shows up or
    /// five seconds pass, so a loaded machine does not fail the test on a line that is only late.
    /// The store can return one event twice, with the same time, thread and message, so each event
    /// counts once; two calls that log the same message still give two lines.
    private func terrainLog(since start: Date, containing needle: String) async throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let subsystem = NSPredicate(format: "subsystem == %@ AND category == %@", "com.lucavallin.maqs", "terrain")
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            try Task.checkCancellation()
            var seen = Set<String>()
            let lines = try store.getEntries(at: store.position(date: start), matching: subsystem)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.composedMessage.contains(needle) }
                .filter { seen.insert("\($0.date.timeIntervalSince1970) \($0.threadIdentifier) \($0.composedMessage)").inserted }
                .map(\.composedMessage)
            if !lines.isEmpty || ContinuousClock.now >= deadline { return lines }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func anArchiveThatFailsToOpenIsLoggedAndThrown() async throws {
        let directory = try TemporaryDirectory()
        // A name of its own, so a line another test logs cannot satisfy this one.
        let name = "corrupt-\(UUID().uuidString).pmtiles"
        let url = directory.url.appending(path: name)
        try Data(repeating: 7, count: 300).write(to: url)
        let start = Date().addingTimeInterval(-1)
        #expect(throws: PMTilesError.notPMTiles) {
            _ = try Terrain(configuration: TerrainConfiguration(archives: [url]))
        }
        let lines = try await terrainLog(since: start, containing: name)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("notPMTiles") == true)
    }

    @Test func setArchivesLogsAnArchiveThatIsNotTerrain() async throws {
        let directory = try TemporaryDirectory()
        let name = "basemap-\(UUID().uuidString).pmtiles"
        let url = directory.url.appending(path: name)
        try FileManager.default.copyItem(at: Fixtures.url("test/test-basemap.v1.pmtiles"), to: url)
        let terrain = try Terrain(configuration: TerrainConfiguration(archives: []))
        let start = Date().addingTimeInterval(-1)
        await #expect(throws: TerrainError.notTerrain(url)) {
            try await terrain.setArchives([url])
        }
        let lines = try await terrainLog(since: start, containing: name)
        #expect(lines.count == 1)
        // The case only: the URL the error carries holds the app's container path.
        #expect(lines.first?.contains("notTerrain") == true)
        #expect(lines.first?.contains(directory.url.path(percentEncoded: false)) == false)
    }
}
