import CoreLocation

/// A line the app asks the map to draw, for example a route or a track, in one run of points or in several separate
/// runs drawn as one line: the stretches of a sight line that are in view, say, all drawn as the one active line.
///
/// Coordinates are WGS 84. Points with a non-finite or out-of-range value are dropped when the line is drawn, a run
/// left with fewer than two points is not drawn, and a line with no run left is not drawn at all. Lines with the same
/// `id` replace each other: the last one wins.
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
    /// The runs of the line, each one's points in order.
    public let segments: [[CLLocationCoordinate2D]]
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
        self.init(id: id, segments: [coordinates], style: style, glows: glows)
    }

    /// Creates a line drawn in several separate runs, which share its id, style and glow: a tap on any of them hits
    /// the line, and it is the active line as a whole.
    ///
    /// - Parameters:
    ///   - id: The app's own identifier.
    ///   - segments: The runs, each one's points in order.
    ///   - style: How the line is drawn.
    ///   - glows: Whether a solid line glows on the dark style.
    public init(id: String, segments: [[CLLocationCoordinate2D]], style: Style = .solid, glows: Bool = false) {
        self.id = id
        self.segments = segments
        self.style = style
        self.glows = glows
    }

    /// Every point of the line, run after run.
    public var coordinates: [CLLocationCoordinate2D] {
        segments.flatMap(\.self)
    }

    public static func == (lhs: MapLine, rhs: MapLine) -> Bool {
        lhs.id == rhs.id && lhs.style == rhs.style && lhs.glows == rhs.glows
            && lhs.segments.count == rhs.segments.count
            && zip(lhs.segments, rhs.segments).allSatisfy { left, right in
                left.count == right.count && zip(left, right).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
            }
    }
}
