import Foundation

/// A terrarium elevation source online, built by the app from MaqsCore's `TileSource`.
///
/// The values are checked once, here, so a source that reaches ``Terrain`` always yields HTTPS tile URLs
/// on the host it names.
public struct OnlineTerrainSource: Sendable, Equatable {
    /// The tile URL template, with `{z}`, `{x}` and `{y}` placeholders.
    public let tiles: String
    /// The image format of the tiles: `webp` or `png`.
    public let format: String
    /// The side of a tile in pixels: 256 or 512.
    public let tileSize: Int
    /// The lowest zoom the source serves.
    public let minZoom: Int
    /// The highest zoom the source serves.
    public let maxZoom: Int

    private static let placeholders = ["{z}", "{x}", "{y}"]
    private static let formats: Set<String> = ["webp", "png"]
    private static let tileSizes: Set<Int> = [256, 512]
    private static let zooms = 0...22

    /// Checks every value and throws ``TerrainError/invalidConfiguration(_:)`` naming the first one that is wrong.
    ///
    /// The template must be an HTTPS URL with a host and no credentials, containing `{z}`, `{x}` and `{y}` and no other
    /// placeholder; the format must be `webp` or `png`; the tile size 256 or 512; and `0 <= minZoom <= maxZoom <= 22`.
    public init(tiles: String, format: String, tileSize: Int, minZoom: Int, maxZoom: Int) throws(TerrainError) {
        for placeholder in Self.placeholders where !tiles.contains(placeholder) {
            throw .invalidConfiguration("the tile template has no \(placeholder)")
        }
        let probe = Self.substitute(tiles, z: 0, x: 0, y: 0)
        guard !probe.contains("{"), !probe.contains("}") else {
            throw .invalidConfiguration("the tile template has a placeholder other than {z}, {x} and {y}")
        }
        guard let components = URLComponents(string: probe) else {
            throw .invalidConfiguration("the tile template is not a URL")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw .invalidConfiguration("the tile template is not HTTPS")
        }
        guard let host = components.host, !host.isEmpty else {
            throw .invalidConfiguration("the tile template has no host")
        }
        guard components.user == nil, components.password == nil else {
            throw .invalidConfiguration("the tile template carries credentials")
        }
        guard Self.formats.contains(format) else {
            throw .invalidConfiguration("the tile format \(format) is neither webp nor png")
        }
        guard Self.tileSizes.contains(tileSize) else {
            throw .invalidConfiguration("the tile size \(tileSize) is neither 256 nor 512")
        }
        guard Self.zooms.contains(minZoom), Self.zooms.contains(maxZoom), minZoom <= maxZoom else {
            throw .invalidConfiguration("the zoom range \(minZoom)...\(maxZoom) is not within 0...22")
        }
        self.tiles = tiles
        self.format = format
        self.tileSize = tileSize
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    /// The URL of one tile. Never nil for a validated template; optional only because `URL(string:)` is.
    func url(for key: TileKey) -> URL? {
        URL(string: Self.substitute(tiles, z: key.z, x: key.x, y: key.y))
    }

    private static func substitute(_ template: String, z: Int, x: Int, y: Int) -> String {
        template.replacing("{z}", with: String(z)).replacing("{x}", with: String(x)).replacing("{y}", with: String(y))
    }
}
