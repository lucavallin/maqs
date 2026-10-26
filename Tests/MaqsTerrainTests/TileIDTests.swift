import Testing
@testable import MaqsTerrain

@Suite struct TileIDTests {
    @Test func idsMatchThePipeline() throws {
        let golden = try Golden.load()
        #expect(!golden.tileIds.isEmpty)
        for value in golden.tileIds {
            #expect(TileID.id(z: value.z, x: value.x, y: value.y) == value.id)
        }
    }

    @Test func outOfRangeTilesHaveNoID() {
        #expect(TileID.id(z: 32, x: 0, y: 0) == nil)
        #expect(TileID.id(z: -1, x: 0, y: 0) == nil)
        #expect(TileID.id(z: 12, x: 1 << 12, y: 0) == nil)
        #expect(TileID.id(z: 12, x: 0, y: 1 << 12) == nil)
        #expect(TileID.id(z: 12, x: 0, y: -1) == nil)
        #expect(TileID.id(z: 12, x: -1, y: 0) == nil)
    }

    @Test func highestZoomDoesNotOverflow() {
        #expect(TileID.id(z: 31, x: (1 << 31) - 1, y: (1 << 31) - 1) != nil)
    }
}
