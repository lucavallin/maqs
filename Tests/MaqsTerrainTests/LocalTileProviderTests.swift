import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsTerrain

@Suite struct LocalTileProviderTests {
    @Test func theTerrainFixtureIsAProvider() throws {
        let provider = try LocalTileProvider(url: Fixtures.url("test/test-terrain.v1.pmtiles"))
        #expect(provider.zoomRange == 0...12)
        #expect(provider.tileSize == 512)
        #expect(!provider.isOnline)
    }

    @Test func theBasemapFixtureIsNotTerrain() throws {
        let url = try Fixtures.url("test/test-basemap.v1.pmtiles")
        #expect(throws: TerrainError.notTerrain(url)) { try LocalTileProvider(url: url) }
    }

    @Test func anArchiveWithoutTileSchemaIsAccepted() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "plain.pmtiles")
        try PMTilesWriter.write(tiles: [(z: 3, x: 1, y: 1, data: Data([1]))], to: url, tileType: 2, metadata: [:])
        let provider = try LocalTileProvider(url: url)
        #expect(provider.zoomRange == 3...3)
        #expect(try provider.covers(TileKey(z: 3, x: 1, y: 1)))
        #expect(try !provider.covers(TileKey(z: 3, x: 2, y: 1)))
    }
}
