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

    @Test(arguments: [256, 512])
    func aTileSizeOf256Or512IsAccepted(_ size: Int) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "sized.pmtiles")
        try PMTilesWriter.write(tiles: [(z: 3, x: 1, y: 1, data: Data([1]))], to: url,
                                metadata: ["tile_schema": "dem/terrarium", "tile_size": size])
        #expect(try LocalTileProvider(url: url).tileSize == size)
    }

    /// 0 would divide by zero when a call sizes its batches, 2^32 would overflow `size * size`, 300 is a size no
    /// terrain source serves, and the rest are not whole numbers.
    static let otherTileSizes: [any Sendable] = [0, 300, 1 << 32, "512", 512.5, true]

    @Test(arguments: otherTileSizes)
    func anyOtherTileSizeIsNotTerrain(_ size: any Sendable) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "sized.pmtiles")
        try PMTilesWriter.write(tiles: [(z: 3, x: 1, y: 1, data: Data([1]))], to: url,
                                metadata: ["tile_schema": "dem/terrarium", "tile_size": size])
        #expect(throws: TerrainError.notTerrain(url)) { try LocalTileProvider(url: url) }
    }
}
