import Foundation

/// The look of the map.
///
/// `.default` is the package's muted style, in a light and a dark variant that follow the interface style.
/// `.custom` takes style JSON in the MapLibre style specification. The package fills in the tile sources,
/// glyphs, sprite and its own content layers, so the JSON needs a vector source named `basemap` and a
/// `layers` array, and no source or layer id may start with `maqs-`.
///
/// - Hillshade needs a `raster-dem` source named `terrain` in the JSON, which the package fills in like `basemap`;
///   a style without one draws no hillshade.
/// - A point-of-interest layer, marked with `"metadata": {"maqs:poi-key": "<OSM key>"}`, needs its `filter`, if it
///   has one, written as an expression. The package wraps it in `["all", filter, …]` with an expression, and MapLibre
///   reads an `all` with a legacy member, such as `["==", "class", "hut"]`, as a legacy filter, in which the package's
///   expression fails to parse.
/// - Any other source in the JSON is fetched by MapLibre directly, past the package's tile gateway: it is asked for
///   inside installed regions and with `MaqsConfiguration.onlineTiles` off too, and offline it draws only what MapLibre
///   cached. An app that needs the map offline adds no remote source.
public enum MapStyle: Sendable, Equatable {
    /// The package's own muted style.
    case `default`
    /// The app's style JSON. `dark` is used in dark mode; without it, `light` is used in both.
    case custom(light: Data, dark: Data?)
}
