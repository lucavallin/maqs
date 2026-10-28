/// One thing a tap on the map touched.
public enum MapHit: Hashable, Sendable {
    /// A marker the app added, by its id.
    case marker(String)
    /// A line the app added, by its id.
    case line(String)
    /// A trail of an installed region's overlay.
    case trail(OverlayFeature)
    /// A place of an installed region's overlay.
    case place(OverlayFeature)
}
