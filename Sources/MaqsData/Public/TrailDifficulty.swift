/// A trail's difficulty: the normalised grade and the source's own value.
public struct TrailDifficulty: Sendable, Equatable {
    /// The normalised grade, 1 (easiest) to 6, or nil when the source gives none.
    public let grade: Int?
    /// The scale the original value is on, such as `sac_scale` or `cai_scale`.
    public let scheme: String?
    /// The value as the source states it, such as `mountain_hiking`.
    public let originalValue: String?
}
