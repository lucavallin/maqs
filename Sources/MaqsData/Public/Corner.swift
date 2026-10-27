import CoreLocation

/// One discrete curve of a road or a recorded track: a maximal run of same-direction vertices tighter than 500 m.
///
/// The same type describes corners read from the road files and corners ``Curvature/analyze(_:)`` finds in a track,
/// found by the same formula (`data-format.md`, Curvature). Distances follow the drawing direction of the line.
public struct Corner: Sendable, Equatable {
    /// The corner's position in the line: 0, 1, … in drawing order.
    public let ordinal: Int
    /// The tightest vertex of the corner.
    public let apex: CLLocationCoordinate2D
    /// The radius in metres of the circle through the corner's entry, apex and exit vertices. It can exceed the
    /// apex vertex's own radius and 500 m. When those three are collinear it is the apex vertex's radius.
    public let minRadius: Double
    /// Which way the corner turns.
    public let turn: Turn
    /// Metres from the first vertex of the line to the vertex before the corner.
    public let entry: Double
    /// Metres from the first vertex of the line to the apex.
    public let apexDistance: Double
    /// Metres from the first vertex of the line to the vertex after the corner.
    public let exit: Double

    /// Creates a corner from its parts.
    public init(
        ordinal: Int, apex: CLLocationCoordinate2D, minRadius: Double, turn: Turn,
        entry: Double, apexDistance: Double, exit: Double
    ) {
        self.ordinal = ordinal
        self.apex = apex
        self.minRadius = minRadius
        self.turn = turn
        self.entry = entry
        self.apexDistance = apexDistance
        self.exit = exit
    }

    /// Two corners are equal when every field is equal, the apex by latitude and longitude.
    public static func == (lhs: Corner, rhs: Corner) -> Bool {
        lhs.ordinal == rhs.ordinal
            && lhs.apex.latitude == rhs.apex.latitude && lhs.apex.longitude == rhs.apex.longitude
            && lhs.minRadius == rhs.minRadius && lhs.turn == rhs.turn
            && lhs.entry == rhs.entry && lhs.apexDistance == rhs.apexDistance && lhs.exit == rhs.exit
    }
}
