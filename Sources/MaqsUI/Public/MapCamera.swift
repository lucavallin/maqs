import CoreLocation
import MaqsCore

/// Where the map looks, as it was when the camera last settled.
public struct MapCamera: Sendable, Equatable {
    /// The coordinate at the centre of the view.
    public let center: CLLocationCoordinate2D
    /// The zoom level, 0 for the whole world.
    public let zoom: Double
    /// The direction the top of the view faces, in degrees clockwise from north.
    public let heading: Double
    /// The tilt from looking straight down, in degrees.
    public let pitch: Double
    /// The coordinates the view shows.
    public let visibleBounds: BoundingBox

    /// Creates a camera description.
    public init(center: CLLocationCoordinate2D, zoom: Double, heading: Double, pitch: Double, visibleBounds: BoundingBox) {
        self.center = center
        self.zoom = zoom
        self.heading = heading
        self.pitch = pitch
        self.visibleBounds = visibleBounds
    }

    public static func == (lhs: MapCamera, rhs: MapCamera) -> Bool {
        lhs.center.latitude == rhs.center.latitude && lhs.center.longitude == rhs.center.longitude
            && lhs.zoom == rhs.zoom && lhs.heading == rhs.heading && lhs.pitch == rhs.pitch
            && lhs.visibleBounds == rhs.visibleBounds
    }
}
