/// A junction where a ``Lookahead`` had more than one way on and guessed which one the rider takes.
public struct Fork: Sendable, Equatable {
    /// Metres ahead of the position.
    public let distance: Double
    /// The branch the walk took.
    public let chosen: RoadBranch
    /// The branches it did not take, by way id, `forward` before `backward`.
    public let alternatives: [RoadBranch]
    /// The last rule that narrowed the branches, which says how good the guess is.
    public let reason: Reason

    /// How the branch was chosen: by the road number, the name or the road class the path carried, or, when none of
    /// those narrowed the branches, by the smallest turn alone. Staying on the same road number is a far likelier
    /// guess than the smallest turn.
    public enum Reason: Sendable, Equatable {
        /// The branch carries the path's last road number (`ref`).
        case sameRef
        /// The branch carries the path's last name.
        case sameName
        /// The branch has the path's last `highway` class.
        case sameHighway
        /// No tag narrowed the branches; the branch turns least.
        case smallestTurn
    }
}
