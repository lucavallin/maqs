import Foundation

/// The online tile providers from `config/sources.json`, one list per layer, in priority order.
///
/// Apps hand these to `MaqsUI` and `MaqsTerrain`, which never import `MaqsCore`. `nil` from
/// ``Maqs/onlineSources`` means the app turned online tiles off.
public struct OnlineSources: Sendable, Equatable {
    /// The `sources_version` of the file these came from.
    public let version: Int
    /// Vector basemap providers, preferred first.
    public let basemap: [TileSource]
    /// Terrain (elevation) providers, preferred first.
    public let terrain: [TileSource]
}

/// One provider entry of `sources.json`, verbatim.
public struct TileSource: Sendable, Equatable, Identifiable {
    /// Stable kebab-case identifier of the entry.
    public let id: String
    /// Human-readable provider name.
    public let provider: String
    /// Tile URL template with `{z}`, `{x}`, `{y}`.
    public let tiles: String
    /// The provider's TileJSON document.
    public let tilejson: URL
    /// `"shortbread-1.0"` or `"terrarium"`.
    public let schema: String
    /// `"mvt"`, `"webp"` or `"png"`.
    public let format: String
    /// Raster tile edge in pixels; `nil` for vector sources.
    public let tileSize: Int?
    /// Lowest zoom the provider serves.
    public let minZoom: Int
    /// Highest zoom the provider serves.
    public let maxZoom: Int
    /// Credits the provider requires, verbatim.
    public let attribution: [String]
}
