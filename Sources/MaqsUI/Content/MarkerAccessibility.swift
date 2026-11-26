import CoreGraphics

/// A marker MapLibre drew, as the map view reads it back from the style.
struct DrawnMarker: Equatable {
    var id: String
    /// The text under the marker, if any.
    var label: String?
    /// What VoiceOver says instead, if the app gave it (``MapMarker/accessibilityLabel``); empty to leave it out.
    var spokenLabel: String?
    var isSelected: Bool
    /// Where it is drawn, in the map view's coordinates.
    var point: CGPoint
}

/// One marker as VoiceOver reaches it: a button over where it is drawn.
struct MarkerAccessibilityItem: Equatable {
    var id: String
    /// The marker's spoken label, else its label, else its id.
    var label: String
    var isSelected: Bool
    /// A ``MarkerAccessibility/side``-point square around the marker, in the map view's coordinates.
    var frame: CGRect
}

/// The accessibility buttons for the markers MapLibre drew, which VoiceOver cannot see on its own.
enum MarkerAccessibility {
    /// The button's side, the minimum hit area.
    static let side: CGFloat = 44

    /// One item per drawn marker inside `bounds`, in reading order (top to bottom, then left to right). A marker drawn
    /// in several tiles comes back from MapLibre once per tile and counts once; a marker whose spoken label is empty is
    /// left out.
    static func items(_ drawn: [DrawnMarker], in bounds: CGRect) -> [MarkerAccessibilityItem] {
        var seen: Set<String> = []
        return drawn
            .filter { bounds.contains($0.point) && seen.insert($0.id).inserted && $0.spokenLabel != "" }
            .sorted { ($0.point.y, $0.point.x) < ($1.point.y, $1.point.x) }
            .map { marker in
                MarkerAccessibilityItem(
                    id: marker.id, label: marker.spokenLabel ?? marker.label ?? marker.id, isSelected: marker.isSelected,
                    frame: CGRect(x: marker.point.x - side / 2, y: marker.point.y - side / 2, width: side, height: side))
            }
    }
}
