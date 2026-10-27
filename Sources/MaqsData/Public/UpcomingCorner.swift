import CoreLocation

/// A corner ahead of a rider, measured along the path of a ``Lookahead``.
public struct UpcomingCorner: Sendable, Equatable {
    /// Which way the corner turns in the direction of travel.
    public let turn: Turn
    /// The corner's radius in metres, as ``Corner/minRadius``.
    public let minRadius: Double
    /// Metres ahead of the position to where the corner begins; negative while the rider is in the corner.
    public let entry: Double
    /// Metres ahead of the position to the tightest point; never negative.
    public let apex: Double
    /// Metres ahead of the position to where the corner ends.
    public let exit: Double
    /// The tightest point.
    public let apexCoordinate: CLLocationCoordinate2D
    /// The OSM way id of the segment the corner is on.
    public let segment: RoadSegment.ID
    /// Whether the corner lies past a fork, on the branch the walk guessed.
    public let afterFork: Bool

    /// Two corners are equal when every field is equal, the apex coordinate by latitude and longitude.
    public static func == (lhs: UpcomingCorner, rhs: UpcomingCorner) -> Bool {
        lhs.turn == rhs.turn && lhs.minRadius == rhs.minRadius
            && lhs.entry == rhs.entry && lhs.apex == rhs.apex && lhs.exit == rhs.exit
            && lhs.apexCoordinate.latitude == rhs.apexCoordinate.latitude
            && lhs.apexCoordinate.longitude == rhs.apexCoordinate.longitude
            && lhs.segment == rhs.segment && lhs.afterFork == rhs.afterFork
    }
}
