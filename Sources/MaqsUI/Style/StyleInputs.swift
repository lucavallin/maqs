import Foundation

/// A tile URL template and the limits of the tiles it serves.
struct TileTemplate: Sendable, Equatable {
    var template: String
    var minZoom: Int
    var maxZoom: Int
    var tileSize: Int?
    var attribution: [String]
}

/// Which overlay layer a PMTiles file holds. The raw value is also the vector source layer name.
enum OverlayLayer: String, Sendable, Equatable {
    case trails
    case places
}

/// An installed region's overlay file.
struct OverlaySource: Sendable, Equatable {
    var region: String
    var layer: OverlayLayer
    var fileURL: URL
}

/// How the package's content layers are drawn.
struct ContentStyle: Sendable, Equatable {
    var dark: Bool
    /// The app's accent colour as `#RRGGBB`.
    var accentHex: String
}

/// Everything the assembler needs besides the base style.
struct StyleInputs: Sendable, Equatable {
    var basemap: TileTemplate
    /// `nil`: no hillshade and no terrain source.
    var terrain: TileTemplate?
    var glyphs: String
    var sprite: String
    var labelLanguage: String?
    var pointsOfInterest: Set<PointOfInterest>
    var overlays: [OverlaySource]
    /// `nil`: every place kind; an empty set hides the places layers.
    var visiblePlaceKinds: Set<String>?
    var showsTrails: Bool
    var content: ContentStyle
}
