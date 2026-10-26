import Testing
@testable import MaqsTerrain

@Suite struct TileCacheTests {
    private func megabyteTile() throws -> ElevationTile {
        try ElevationTile(size: 512, elevations: [Float](repeating: 1, count: 512 * 512))
    }

    private func source(_ index: Int) -> SourceTile {
        SourceTile(provider: 0, key: TileKey(z: 12, x: index, y: 0))
    }

    @Test func theByteBoundHoldsUnderASweep() throws {
        let cache = TileCache(byteLimit: 10 << 20)
        let tile = try megabyteTile()
        for index in 0..<100 {
            cache.insert(tile, for: source(index))
            #expect(cache.byteCount <= 10 << 20)
        }
        #expect(cache.byteCount == 10 << 20)
    }

    @Test func leastRecentlyUsedGoesFirst() throws {
        let cache = TileCache(byteLimit: 3 << 20)
        let tile = try megabyteTile()
        let (a, b, c, d) = (source(0), source(1), source(2), source(3))
        cache.insert(tile, for: a)
        cache.insert(tile, for: b)
        cache.insert(tile, for: c)
        #expect(cache.tile(for: a) != nil)
        cache.insert(tile, for: d)
        #expect(cache.tile(for: b) == nil)
        #expect(cache.tile(for: a) != nil)
        #expect(cache.tile(for: c) != nil)
        #expect(cache.tile(for: d) != nil)
    }

    @Test func aTileLargerThanTheLimitIsNotKept() throws {
        let cache = TileCache(byteLimit: 1 << 19)
        cache.insert(try megabyteTile(), for: source(0))
        #expect(cache.tile(for: source(0)) == nil)
        #expect(cache.byteCount == 0)
    }
}
