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
    /// How much the marker matters next to the other ranked ones. A ranked marker gives way: where ranked markers would
    /// overlap, the higher rank is drawn and the others are left out until there is room, and a label that does not
    /// fit goes before its marker. An unranked marker, nil, is always drawn, as is the selected one.
    public let rank: Double?
    /// What VoiceOver says for the marker, when its label alone does not say enough (that a place is dimmed, say).
    /// Nil reads the label, else the id; an empty string leaves the marker out of VoiceOver, for one that only
    /// decorates.
    public let accessibilityLabel: String?

    /// Creates a marker.
    ///
    /// - Parameters:
    ///   - id: The app's own identifier.
    ///   - coordinate: Where the marker is.
    ///   - content: What the marker shows.
    ///   - label: A text under the marker, if any.
    ///   - isHidden: Whether the marker is drawn muted.
    ///   - rank: How much the marker matters, for markers that give way to one another; nil to always draw it.
    ///   - accessibilityLabel: What VoiceOver says for it; nil reads the label, empty leaves it out.
    public init(
        id: String, coordinate: CLLocationCoordinate2D, content: MarkerContent = .dot, label: String? = nil,
        isHidden: Bool = false, rank: Double? = nil, accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.coordinate = coordinate
        self.content = content
        self.label = label
        self.isHidden = isHidden
        self.rank = rank
        self.accessibilityLabel = accessibilityLabel
    }
}
#endif
