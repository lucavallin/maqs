import SwiftUI

/// How the map looks: the style, the accent, hillshade, the label language and the points of interest.
///
/// Changing any of these rebuilds the style; the camera and the downloaded files stay.
public struct MapConfiguration: Sendable, Equatable {
    /// The base style: the package's muted default, or the app's own style JSON.
    public var style: MapStyle
    /// The colour of the one active line and the selected marker's halo. The user's location is always blue.
    public var accent: Color
    /// Whether the map draws a subtle hillshade. It needs `.terrain` in the `MaqsConfiguration` layers; without it
    /// there is no hillshade whatever this says.
    public var showsHillshade: Bool
    /// The language code of the labels, for example `"it"`. A label falls back to the local name where the tiles
    /// carry no name in that language. `nil` uses the device's language.
    public var labelLanguage: String?
    /// The kinds of point of interest the basemap shows; none by default.
    public var pointsOfInterest: Set<PointOfInterest>
    /// The size of MapLibre's tile cache on disk, which keeps tiles seen online for use without a network. It applies
    /// only when the first ``MaqsMap`` of the process is created; `nil` keeps MapLibre's default of 50 MiB.
    public var ambientCacheBytes: Int?

    /// Creates a configuration; every value has a default.
    ///
    /// - Parameters:
    ///   - style: The base style.
    ///   - accent: The colour of the active line and the selected marker.
    ///   - showsHillshade: Whether the map draws hillshade where terrain is available.
    ///   - labelLanguage: The language code of the labels; `nil` for the device's language.
    ///   - pointsOfInterest: The kinds of point of interest to show.
    ///   - ambientCacheBytes: The size of MapLibre's tile cache, applied once per process.
    public init(
        style: MapStyle = .default, accent: Color = .accentColor, showsHillshade: Bool = true,
        labelLanguage: String? = nil, pointsOfInterest: Set<PointOfInterest> = [], ambientCacheBytes: Int? = nil
    ) {
        self.style = style
        self.accent = accent
        self.showsHillshade = showsHillshade
        self.labelLanguage = labelLanguage
        self.pointsOfInterest = pointsOfInterest
        self.ambientCacheBytes = ambientCacheBytes
    }
}
