/// What lies ahead of a rider along the road: the corners, the path the walk took to find them, and where it had
/// to guess.
public struct Lookahead: Sendable, Equatable {
    /// The corners whose apex lies ahead within the distance asked for, nearest first.
    public let corners: [UpcomingCorner]
    /// The segments walked, starting with the rider's own. Going straight on along a segment past a junction stays
    /// in its step; a segment comes again only where the walk enters it anew, as across a ring's closing node or
    /// back onto a road it left.
    public let path: [PathStep]
    /// The junctions where the walk chose among several branches, nearest first.
    public let forks: [Fork]
    /// Why the walk stopped.
    public let end: End

    /// Why a walk stopped.
    public enum End: Sendable, Equatable {
        /// The path reached the distance asked for.
        case reachedDistance
        /// The road ends at a node, this many metres ahead, with no way on in the open files: a dead end, a road
        /// that leaves the region, a one-way road the walk may not enter, or a road the curvature layer leaves out
        /// (residential or unpaved). The walk also stops where every way on is already on its path, at the end of a
        /// loop.
        case noContinuation(at: Double)
    }
}
