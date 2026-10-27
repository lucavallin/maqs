/// One segment of a ``Lookahead``'s path, in the order the walk travels them.
public struct PathStep: Sendable, Equatable {
    /// The OSM way id of the segment.
    public let segment: RoadSegment.ID
    /// The direction of travel along it, relative to its drawing direction.
    public let direction: TravelDirection
    /// Where the walk enters it, in metres from its first vertex in drawing direction: the position's own `along`
    /// for the first step.
    public let along: Double
    /// Metres ahead of the position where the step starts: 0 for the first step.
    public let distance: Double
}
