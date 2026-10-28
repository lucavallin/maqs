#if canImport(UIKit)
import CoreLocation

/// A marker the app asks the map to draw.
///
/// A marker with a non-finite or out-of-range coordinate is not drawn. Markers with the same `id` replace each other:
/// the last one wins.
public struct MapMarker: Identifiable, Sendable {
    /// The app's own identifier for the marker.
    public let id: String
    /// Where the marker is.
    public let coordinate: CLLocationCoordinate2D
    /// What the marker shows.
    public let content: MarkerContent
    /// A text under the marker, if any.
    public let label: String?
    /// Whether the marker is drawn muted, for something that is not part of the current choice.
    public let isHidden: Bool

    /// Creates a marker.
    ///
    /// - Parameters:
    ///   - id: The app's own identifier.
    ///   - coordinate: Where the marker is.
    ///   - content: What the marker shows.
    ///   - label: A text under the marker, if any.
    ///   - isHidden: Whether the marker is drawn muted.
    public init(
        id: String, coordinate: CLLocationCoordinate2D, content: MarkerContent = .dot, label: String? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.coordinate = coordinate
        self.content = content
        self.label = label
        self.isHidden = isHidden
    }
}
#endif
