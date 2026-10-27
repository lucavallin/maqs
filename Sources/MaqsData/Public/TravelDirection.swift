/// Which way a rider travels along a road segment, relative to its drawing direction.
public enum TravelDirection: Sendable, Hashable {
    /// From the first vertex towards the last.
    case forward
    /// From the last vertex towards the first.
    case backward
}
