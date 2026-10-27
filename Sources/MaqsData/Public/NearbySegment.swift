/// A road segment close to a position, with where on it the position lies.
public struct NearbySegment: Sendable {
    /// The segment.
    public let segment: RoadSegment
    /// Metres from the position to the nearest point of the segment.
    public let distance: Double
    /// Metres along the segment from its first vertex to that nearest point.
    public let along: Double
    /// The segment's drawing direction at the nearest point, in degrees clockwise from north.
    public let heading: Double
}
