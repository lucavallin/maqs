import CoreLocation
import Foundation
import MaqsTestSupport
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
}
