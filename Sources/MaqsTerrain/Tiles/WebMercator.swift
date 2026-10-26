import Foundation

/// Web Mercator tile arithmetic, mirroring the pipeline's `lonlat_to_pixel`.
enum WebMercator {
    private static let maxLatitude = 85.05
    private static let equatorRadius = 6_378_137.0

    /// The tile holding a position and the pixel inside it, or nil for non-finite input or `|latitude| >= 85.05`.
    /// Longitude is normalised to [-180, 180) first, so 180 and -180 are the same meridian.
    static func position(longitude: Double, latitude: Double, zoom: Int, tileSize: Int) -> (key: TileKey, pixelX: Double, pixelY: Double)? {
        guard longitude.isFinite, latitude.isFinite, abs(latitude) < maxLatitude, (0...30).contains(zoom), tileSize > 0 else {
            return nil
        }
        let tiles = 1 << zoom
        let count = Double(tiles)
        var wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        let fractionalX = wrapped / 360 * count
        let radians = latitude * .pi / 180
        let fractionalY = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * count
        let tileX = min(Int(fractionalX.rounded(.down)), tiles - 1)
        let tileY = min(max(Int(fractionalY.rounded(.down)), 0), tiles - 1)
        let size = Double(tileSize)
        return (
            TileKey(z: zoom, x: tileX, y: tileY),
            (fractionalX - Double(tileX)) * size,
            (fractionalY - Double(tileY)) * size
        )
    }

    /// Metres covered by one pixel at this latitude.
    static func pixelSize(zoom: Int, tileSize: Int, latitude: Double) -> Double {
        cos(latitude * .pi / 180) * 2 * .pi * equatorRadius / (Double(tileSize) * Double(1 << zoom))
    }
}
