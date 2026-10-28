/// Which overlays of the installed regions the map draws. Overlays exist only inside installed regions whose pack has
/// the layer; online there are none.
public struct MapOverlays: Sendable, Equatable {
    /// Whether the trails overlay is drawn.
    public var trails: Bool
    /// The place kinds drawn, as the places layer names them (`peak`, `saddle`, `alpine_hut`, …). An empty set draws
    /// no places; `nil` draws every kind.
    public var places: Set<String>?

    /// Creates an overlay choice; by default nothing is drawn.
    ///
    /// - Parameters:
    ///   - trails: Whether the trails overlay is drawn.
    ///   - places: The place kinds drawn; empty for none, `nil` for every kind.
    public init(trails: Bool = false, places: Set<String>? = []) {
        self.trails = trails
        self.places = places
    }
}
