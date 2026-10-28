import CoreLocation

/// A tap on the map: where it landed and what it touched.
public struct MapTap: Sendable {
    /// The coordinate under the tap.
    public let coordinate: CLLocationCoordinate2D
    /// What the tap touched, topmost first. Overlapping installed regions give one hit per region for the same
    /// trail or place.
    public let hits: [MapHit]

    /// Creates a tap.
    public init(coordinate: CLLocationCoordinate2D, hits: [MapHit]) {
        self.coordinate = coordinate
        self.hits = hits
    }
}
