import CoreLocation

/// How high the observer's eye is.
public enum ObserverHeight: Sendable, Equatable {
    /// Metres above the ground at the observer's position. The ground is sampled, so a position with no data is ``Visibility/unknown(at:reason:distance:)``.
    case aboveGround(Double)
    /// Metres above sea level; no ground sample is needed.
    case absolute(Double)
}

/// Where the user stands and how high their eye is.
public struct Observer: Sendable {
    /// The observer's position.
    public var coordinate: CLLocationCoordinate2D
    /// The eye height; 1.7 m above the ground by default.
    public var height: ObserverHeight

    /// Creates an observer.
    public init(coordinate: CLLocationCoordinate2D, height: ObserverHeight = .aboveGround(1.7)) {
        self.coordinate = coordinate
        self.height = height
    }
}
