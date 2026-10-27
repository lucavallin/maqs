/// A trail's stable key across data releases and installed files: its source and the source's own id.
public struct TrailID: Sendable, Hashable {
    /// The trail source adapter, such as `osm`.
    public let source: String
    /// The id in that source, such as `relation/14563614`.
    public let sourceID: String

    /// Creates the key of a trail.
    public init(source: String, sourceID: String) {
        self.source = source
        self.sourceID = sourceID
    }
}
