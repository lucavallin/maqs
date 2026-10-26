import Testing
@testable import MaqsTerrain

@Suite struct WebMercatorTests {
    @Test func theTestBboxCentreIsTile12_2187_1455() throws {
        let position = try #require(WebMercator.position(longitude: 12.25, latitude: 46.105, zoom: 12, tileSize: 512))
        #expect(position.key == TileKey(z: 12, x: 2187, y: 1455))
        #expect((0..<512).contains(position.pixelX))
        #expect((0..<512).contains(position.pixelY))
    }

    @Test func pixelSizeAtZoom12And46Degrees() {
        let size = WebMercator.pixelSize(zoom: 12, tileSize: 512, latitude: 46.1)
        #expect((13.25...13.35).contains(size))
    }

    @Test func noPositionAtThePolesOrForNaN() {
        #expect(WebMercator.position(longitude: 0, latitude: 85.05, zoom: 5, tileSize: 512) == nil)
        #expect(WebMercator.position(longitude: 0, latitude: -90, zoom: 5, tileSize: 512) == nil)
        #expect(WebMercator.position(longitude: .nan, latitude: 0, zoom: 5, tileSize: 512) == nil)
        #expect(WebMercator.position(longitude: 0, latitude: .infinity, zoom: 5, tileSize: 512) == nil)
    }

    @Test func longitude180WrapsToTileX0() throws {
        let east = try #require(WebMercator.position(longitude: 180, latitude: 10, zoom: 6, tileSize: 512))
        let west = try #require(WebMercator.position(longitude: -180, latitude: 10, zoom: 6, tileSize: 512))
        #expect(east.key.x == 0)
        #expect(west.key.x == 0)
    }

    @Test(arguments: [-540.0, -181.0, -179.999, 0, 179.999, 180, 360, 725])
    func tileXStaysInRange(longitude: Double) throws {
        let position = try #require(WebMercator.position(longitude: longitude, latitude: 0, zoom: 7, tileSize: 256))
        #expect((0..<1 << 7).contains(position.key.x))
    }
}
