import CoreLocation

/// Something to look at, such as a peak.
public struct SightTarget: Sendable {
    /// The target's position.
    public var coordinate: CLLocationCoordinate2D
    /// The real height in metres above sea level, when known (for a peak, its OSM `ele`).
    ///
    /// Terrain tiles flatten summits, so with this the sight line aims at the true summit; without it, at the sampled ground.
    /// A value that is not finite is ignored.
    public var elevation: Double?

    /// Creates a target.
    public init(coordinate: CLLocationCoordinate2D, elevation: Double? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
    }
}
