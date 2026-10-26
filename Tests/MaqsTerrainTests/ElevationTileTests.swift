import Testing
@testable import MaqsTerrain

@Suite struct ElevationTileTests {
    private func tile() throws -> ElevationTile {
        try ElevationTile(size: 2, elevations: [10, 20, 30, 50])
    }

    @Test func returnsExactValuesAtPixelCentres() throws {
        let tile = try tile()
        #expect(tile.elevation(pixelX: 0.5, pixelY: 0.5) == 10)
        #expect(tile.elevation(pixelX: 1.5, pixelY: 0.5) == 20)
        #expect(tile.elevation(pixelX: 0.5, pixelY: 1.5) == 30)
        #expect(tile.elevation(pixelX: 1.5, pixelY: 1.5) == 50)
    }

    @Test func midpointOfFourCentresIsTheirMean() throws {
        #expect(try tile().elevation(pixelX: 1, pixelY: 1) == 27.5)
    }

    @Test func clampsOutsideTheOuterCentres() throws {
        let tile = try tile()
        #expect(tile.elevation(pixelX: 0, pixelY: 0) == 10)
        #expect(tile.elevation(pixelX: 0.2, pixelY: 0.1) == 10)
        #expect(tile.elevation(pixelX: 2, pixelY: 2) == 50)
        #expect(tile.elevation(pixelX: 1.9, pixelY: 1.8) == 50)
    }

    @Test func rejectsAWrongElementCount() {
        #expect(throws: TerrainError.self) { try ElevationTile(size: 2, elevations: [1, 2, 3]) }
        #expect(throws: TerrainError.self) { try ElevationTile(size: 0, elevations: []) }
    }

    @Test func reportsItsByteCount() throws {
        #expect(try tile().byteCount == 16)
    }
}
