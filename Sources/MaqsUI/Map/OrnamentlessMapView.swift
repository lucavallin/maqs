#if canImport(MapLibre)
import MapLibre
import UIKit

/// MapLibre's view without its ornaments among its accessibility children.
///
/// `MLNMapView` answers the accessibility container calls with the compass and the attribution button whatever they
/// show, so the accessibility tree keeps both nodes while the map hides them, and VoiceOver could open MapLibre's own
/// credits sheet. This view leaves them and the logo out and passes every other child through in MapLibre's order:
/// the user's location, annotations and the map element itself.
final class OrnamentlessMapView: MLNMapView {
    /// MapLibre's accessibility children without the ornaments, read again on every call: MapLibre's own list
    /// changes as the location, annotations and callouts come and go.
    private var accessibleChildren: [Any] {
        let ornaments: [UIView] = [compassView, attributionButton, logoView]
        let count = super.accessibilityElementCount()
        guard count != NSNotFound, count > 0 else { return [] }
        var children: [Any] = []
        for index in 0..<count {
            guard let child = super.accessibilityElement(at: index) else { continue }
            if ornaments.contains(where: { $0 === child as AnyObject }) { continue }
            children.append(child)
        }
        return children
    }

    override func accessibilityElementCount() -> Int {
        accessibleChildren.count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        let children = accessibleChildren
        return children.indices.contains(index) ? children[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        accessibleChildren.firstIndex { $0 as AnyObject === element as AnyObject } ?? NSNotFound
    }
}
#endif
