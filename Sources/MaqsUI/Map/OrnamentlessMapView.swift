#if canImport(MapLibre)
import MapLibre
import UIKit

/// MapLibre's view without its ornaments among its accessibility children, and with the app's markers among them.
///
/// `MLNMapView` answers the accessibility container calls with the compass and the attribution button whatever they
/// show, so the accessibility tree keeps both nodes while the map hides them, and VoiceOver could open MapLibre's own
/// credits sheet. This view leaves them and the logo out and passes every other child through in MapLibre's order:
/// the user's location, annotations and the map element itself. After them come the markers MapLibre drew, which
/// VoiceOver cannot otherwise reach: one button each, made by ``markerElements`` and kept until
/// ``invalidateMarkerElements()``.
final class OrnamentlessMapView: MLNMapView {
    /// Makes the accessibility buttons of the markers drawn now.
    var markerElements: () -> [Any] = { [] }
    private var cachedMarkerElements: [Any]?

    /// Forgets the marker buttons, after the camera or the markers changed; the next accessibility call makes them again.
    func invalidateMarkerElements() {
        cachedMarkerElements = nil
    }

    /// MapLibre's accessibility children without the ornaments, read again on every call: MapLibre's own list
    /// changes as the location, annotations and callouts come and go.
    private var accessibleChildren: [Any] {
        let ornaments: [UIView] = [compassView, attributionButton, logoView]
        let count = super.accessibilityElementCount()
        var children: [Any] = []
        if count != NSNotFound {
            for index in 0..<max(count, 0) {
                guard let child = super.accessibilityElement(at: index) else { continue }
                if ornaments.contains(where: { $0 === child as AnyObject }) { continue }
                children.append(child)
            }
        }
        let markers = cachedMarkerElements ?? markerElements()
        cachedMarkerElements = markers
        return children + markers
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
/// A drawn marker as VoiceOver reaches it: activating it taps the map on the marker.
final class MarkerAccessibilityElement: UIAccessibilityElement {
    var onActivate: () -> Void = {}

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }
}
#endif
