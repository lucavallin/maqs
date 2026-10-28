import Foundation

/// The look of the map.
///
/// `.default` is the package's muted style, in a light and a dark variant that follow the interface style.
/// `.custom` takes style JSON in the MapLibre style specification. The package fills in the tile sources,
/// glyphs, sprite and its own content layers, so the JSON needs a vector source named `basemap` and a
/// `layers` array, and no source or layer id may start with `maqs-`.
public enum MapStyle: Sendable, Equatable {
    /// The package's own muted style.
    case `default`
    /// The app's style JSON. `dark` is used in dark mode; without it, `light` is used in both.
    case custom(light: Data, dark: Data?)
}
