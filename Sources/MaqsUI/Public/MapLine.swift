import CoreLocation

/// A line the app asks the map to draw, for example a route or a track.
///
/// Coordinates are WGS 84. Points with a non-finite or out-of-range value are dropped when the line is drawn,
/// and a line left with fewer than two points is not drawn at all. Lines with the same `id` replace each other:
/// the last one wins.
public struct MapLine: Identifiable, Sendable, Equatable {
    /// How a line is drawn.
    public enum Style: Sendable, Equatable {
        /// A solid line with a casing.
        case solid
        /// A thin dashed grey line, for a line that is not part of the current choice.
        case hidden
    }

    /// The app's own identifier for the line.
    public let id: String
    /// The points of the line, in order.
    public let coordinates: [CLLocationCoordinate2D]
    /// How the line is drawn.
    public let style: Style
    /// Whether a solid line gets a glow on the dark style.
    public let glows: Bool

    /// Creates a line.
    ///
    /// - Parameters:
    ///   - id: The app's own identifier.
    ///   - coordinates: The points of the line, in order.
    ///   - style: How the line is drawn.
    ///   - glows: Whether a solid line glows on the dark style.
    public init(id: String, coordinates: [CLLocationCoordinate2D], style: Style = .solid, glows: Bool = false) {
        self.id = id
        self.coordinates = coordinates
        self.style = style
        self.glows = glows
    }

    public static func == (lhs: MapLine, rhs: MapLine) -> Bool {
        lhs.id == rhs.id && lhs.style == rhs.style && lhs.glows == rhs.glows
            && lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}
