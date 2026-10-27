/// One way to leave a junction: a segment and the direction it is travelled in from there.
public struct RoadBranch: Sendable, Hashable {
    /// The OSM way id of the segment.
    public let segment: RoadSegment.ID
    /// The direction of travel along it, relative to its drawing direction.
    public let direction: TravelDirection
}
