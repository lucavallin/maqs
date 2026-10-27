/// A place's stable key across data releases and installed files: the OSM object it was made from.
public struct PlaceID: Sendable, Hashable {
    /// The OSM object type; `node` in today's files.
    public let osmType: String
    /// The OSM id within that type.
    public let osmID: Int64

    /// Creates the key of a place.
    public init(osmType: String, osmID: Int64) {
        self.osmType = osmType
        self.osmID = osmID
    }
}
