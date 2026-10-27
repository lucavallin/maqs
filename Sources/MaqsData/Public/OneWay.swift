/// Which way traffic may drive along a road segment, relative to its drawing direction.
public enum OneWay: Sendable, Equatable {
    /// Both ways.
    case none
    /// Only from the first vertex to the last.
    case forward
    /// Only from the last vertex to the first.
    case backward
}
