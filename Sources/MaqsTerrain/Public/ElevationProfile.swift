import CoreLocation
import Foundation

/// One sample along a profile.
public struct ProfilePoint: Sendable {
    /// Metres from the start along the great circle.
    public let distance: Double
    /// Where the sample was taken.
    public let coordinate: CLLocationCoordinate2D
    /// The terrain elevation in metres above sea level, or why there is none.
    public let ground: ElevationSample
    /// The ground elevation minus the Earth's curvature drop at `distance`; `nil` exactly when `ground` is missing.
    public let apparentElevation: Double?
}

/// Elevations along the great circle between two positions, from the start to the end.
public struct ElevationProfile: Sendable {
    /// The samples in order of distance; the first is at 0 and the last at the full distance.
    public let points: [ProfilePoint]
}
