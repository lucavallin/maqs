import CoreLocation

/// Whether the observer can see one target.
public enum Visibility: Sendable {
    /// Nothing known hides the target and no ground along the line is missing.
    /// - Parameters:
    ///   - distance: Metres along the great circle.
    ///   - bearing: Degrees clockwise from north, 0 up to but not including 360.
    ///   - elevationAngle: Degrees above the horizontal at which the target appears, from the observer's eye.
    case visible(distance: Double, bearing: Double, elevationAngle: Double)
    /// Ground rises above the sight line by more than the margin.
    /// - Parameters:
    ///   - distance: Metres to the target.
    ///   - blockedAt: The sample that clears the sight line by the most.
    ///   - blockedDistance: Metres from the observer to `blockedAt`.
    ///   - clearance: Metres by which that ground rises above the sight line.
    case hidden(distance: Double, blockedAt: CLLocationCoordinate2D, blockedDistance: Double, clearance: Double)
    /// No known ground hides the target, but some height needed for the answer is missing.
    case unknown(at: MissingHeight, reason: MissingReason, distance: Double)
    /// The target is farther than ``VisibilityOptions/maxDistance``.
    case outOfRange(distance: Double)

    /// Which height is missing.
    public enum MissingHeight: Sendable, Equatable {
        /// The ground at the observer, needed for an ``ObserverHeight/aboveGround(_:)`` eye.
        case observer
        /// The ground at the target, needed when the target has no ``SightTarget/elevation``; also a target position that is not a coordinate.
        case target
        /// Ground along the line between them.
        case path
    }
}
