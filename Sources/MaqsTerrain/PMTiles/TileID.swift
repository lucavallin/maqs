/// PMTiles v3 tile ids: the position of a tile along the Hilbert curve, after every tile of the lower zooms.
enum TileID {
    /// The id of tile `z/x/y`, or `nil` outside zoom 0...31 and `0..<2^z` for `x` and `y`.
    static func id(z: Int, x: Int, y: Int) -> UInt64? {
        guard (0...31).contains(z), x >= 0, y >= 0 else { return nil }
        let n = UInt64(1) << UInt64(z)
        var x = UInt64(x)
        var y = UInt64(y)
        guard x < n, y < n else { return nil }
        // Tiles in all lower zooms; at z31 this is below 2^62, so nothing here overflows.
        let lowerZooms = ((UInt64(1) << UInt64(2 * z)) - 1) / 3
        var distance: UInt64 = 0
        var s = n >> 1
        while s > 0 {
            let rx: UInt64 = x & s != 0 ? 1 : 0
            let ry: UInt64 = y & s != 0 ? 1 : 0
            distance += s * s * ((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 {
                    x = n - 1 - x
                    y = n - 1 - y
                }
                swap(&x, &y)
            }
            s >>= 1
        }
        return lowerZooms + distance
    }
}
