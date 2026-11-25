import CoreGraphics

/// One marker as VoiceOver reaches it: a button over where it is drawn.
struct MarkerAccessibilityItem: Equatable {
    var id: String
    /// The marker's label, or its id when it has none.
    var label: String
    /// A ``MarkerAccessibility/side``-point square around the marker, in the map view's coordinates.
    var frame: CGRect
}

/// The accessibility buttons for the markers MapLibre drew, which VoiceOver cannot see on its own.
enum MarkerAccessibility {
    /// The button's side, the minimum hit area.
    static let side: CGFloat = 44

    /// One item per drawn marker inside `bounds`, in reading order (top to bottom, then left to right). A marker drawn
    /// in several tiles comes back from MapLibre once per tile and counts once.
    static func items(_ drawn: [(id: String, label: String?, point: CGPoint)], in bounds: CGRect) -> [MarkerAccessibilityItem] {
        var seen: Set<String> = []
        return drawn
            .filter { bounds.contains($0.point) && seen.insert($0.id).inserted }
            .sorted { ($0.point.y, $0.point.x) < ($1.point.y, $1.point.x) }
            .map { marker in
                MarkerAccessibilityItem(
                    id: marker.id, label: marker.label ?? marker.id,
                    frame: CGRect(x: marker.point.x - side / 2, y: marker.point.y - side / 2, width: side, height: side))
            }
    }
}
