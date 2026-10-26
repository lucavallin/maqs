import Testing
@testable import MaqsTerrain

@Suite struct ZoomBandsTests {
    @Test func standardBandsPickTheZoomForTheDistance() {
        let bands = ZoomBands.standard
        #expect(bands.zoom(atDistance: 0) == 12)
        #expect(bands.zoom(atDistance: 5_000) == 12)
        #expect(bands.zoom(atDistance: 10_000) == 12)
        #expect(bands.zoom(atDistance: 10_001) == 11)
        #expect(bands.zoom(atDistance: 35_000) == 10)
        #expect(bands.zoom(atDistance: 50_000) == 9)
    }

    @Test func rejectsDecreasingBands() {
        #expect(throws: TerrainError.self) {
            try ZoomBands([ZoomBand(upTo: 20_000, zoom: 12), ZoomBand(upTo: 10_000, zoom: 11), ZoomBand(upTo: .infinity, zoom: 9)])
        }
    }

    @Test func rejectsABandListWithoutAnInfiniteLastBand() {
        #expect(throws: TerrainError.self) { try ZoomBands([ZoomBand(upTo: 10_000, zoom: 12)]) }
    }

    @Test func rejectsAnEmptyListAndOutOfRangeZooms() {
        #expect(throws: TerrainError.self) { try ZoomBands([]) }
        #expect(throws: TerrainError.self) { try ZoomBands([ZoomBand(upTo: .infinity, zoom: 23)]) }
        #expect(throws: TerrainError.self) { try ZoomBands([ZoomBand(upTo: .infinity, zoom: -1)]) }
    }

    @Test func acceptsASingleInfiniteBand() throws {
        #expect(try ZoomBands([ZoomBand(upTo: .infinity, zoom: 7)]).zoom(atDistance: 1e9) == 7)
    }
}
