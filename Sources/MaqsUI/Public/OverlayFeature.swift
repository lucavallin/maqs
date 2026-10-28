/// One trail or place of an installed region's overlay: the values `MaqsData`'s `trail(region:featureID:)` and
/// `place(region:featureID:)` take to read its record.
public struct OverlayFeature: Hashable, Sendable {
    /// The id of the region whose overlay holds the feature, for example `"veneto"`.
    public let region: String
    /// The feature's id in that region's overlay.
    public let featureID: Int64

    /// Creates a reference to an overlay feature.
    public init(region: String, featureID: Int64) {
        self.region = region
        self.featureID = featureID
    }
}
