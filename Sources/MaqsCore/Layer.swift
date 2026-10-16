/// A data layer of a region pack, as named in `manifest.json` and `docs/data-format.md`.
///
/// Apps declare the layers they need in ``MaqsConfiguration/layers``; only those are listed in the catalog and downloaded.
public enum Layer: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    /// Shortbread vector tiles (PMTiles).
    case basemap
    /// Terrarium DEM tiles, zoom 0–12 (PMTiles).
    case terrain
    /// Optional higher-zoom terrain (PMTiles); the manifest key is `terrain-hd`.
    case terrainHD = "terrain-hd"
    /// Trails: a SQLite file and an overlay tile file.
    case trails
    /// Places: a SQLite file and an overlay tile file.
    case places
    /// Road curvature segments and corners (SQLite).
    case curvature
}
