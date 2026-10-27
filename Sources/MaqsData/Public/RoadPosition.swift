/// Where a rider is on a road, as the app's map-matcher decided: a segment, the direction of travel along it, and
/// how far along it.
public struct RoadPosition: Sendable {
    /// The segment the rider is on, from ``Roads/segments(near:within:limit:)`` or ``Roads/segment(_:)``.
    public let segment: RoadSegment
    /// The direction of travel, relative to the segment's drawing direction.
    public let direction: TravelDirection
    /// Metres from the segment's first vertex, in drawing direction whichever way the rider travels, as
    /// ``NearbySegment/along`` gives it.
    public let along: Double

    /// Creates a position. ``Roads/cornersAhead(from:distance:)`` checks it: `along` must be finite, and is clamped
    /// to the segment's length there.
    public init(segment: RoadSegment, direction: TravelDirection, along: Double) {
        self.segment = segment
        self.direction = direction
        self.along = along
    }
}
