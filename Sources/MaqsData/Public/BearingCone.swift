import CoreLocation

/// A sector of a circle around a position: what lies along a sight line.
public struct BearingCone: Sendable {
    /// The position the cone opens from.
    public let origin: CLLocationCoordinate2D
    /// The direction of the cone's axis in degrees clockwise from north, in 0..<360.
    public let bearing: Double
    /// How far either side of the axis the cone reaches, in degrees, above 0 and at most 180.
    public let halfAngle: Double
    /// How far the cone reaches in metres, above 0 and at most 500,000.
    public let maxDistance: Double

    /// Creates a cone from an origin and a direction.
    ///
    /// - Parameters:
    ///   - origin: A real position; places less than 1 m away have no direction and are never found.
    ///   - bearing: Any finite angle in degrees; it is normalised to 0..<360.
    ///   - halfAngle: Above 0 and at most 180; 180 is a full circle.
    ///   - maxDistance: Above 0 and at most 500,000 m.
    /// - Throws: ``QueryError/invalidInput(_:)`` when a value is out of range or not a usable number, including
    ///   the no-fix coordinate.
    public init(
        origin: CLLocationCoordinate2D, bearing: Double, halfAngle: Double = 5, maxDistance: Double = 100_000
    ) throws(QueryError) {
        guard Geodesy.isValid(origin) else { throw .invalidInput("origin is not a valid coordinate") }
        guard bearing.isFinite else { throw .invalidInput("bearing must be a finite number") }
        guard halfAngle > 0, halfAngle <= 180 else { throw .invalidInput("halfAngle must be above 0 and at most 180") }
        guard maxDistance > 0, maxDistance <= 500_000 else {
            throw .invalidInput("maxDistance must be above 0 and at most 500000")
        }
        let wrapped = bearing.truncatingRemainder(dividingBy: 360)
        let normalised = wrapped < 0 ? wrapped + 360 : wrapped
        self.origin = origin
        self.bearing = normalised < 360 ? normalised : 0
        self.halfAngle = halfAngle
        self.maxDistance = maxDistance
    }

    /// Creates a cone that opens from `from` towards `to` and reaches as far as `to`.
    ///
    /// - Throws: ``QueryError/invalidInput(_:)`` when a point is not a real position, the points are less than 1 m
    ///   apart (no direction), more than 500,000 m apart, or `halfAngle` is out of range.
    public init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, halfAngle: Double = 5) throws(QueryError) {
        guard Geodesy.isValid(from), Geodesy.isValid(to) else {
            throw .invalidInput("from and to must be valid coordinates")
        }
        let distance = Geodesy.distance(from, to)
        guard distance >= 1 else { throw .invalidInput("from and to must be at least 1 m apart") }
        try self.init(
            origin: from, bearing: Geodesy.initialBearing(from: from, to: to), halfAngle: halfAngle, maxDistance: distance)
    }
}
