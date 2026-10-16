/// One region or base pack as the catalog shows it to the app.
public struct PackSummary: Sendable, Equatable, Identifiable {
    /// The pack this summary describes.
    public let id: PackID
    /// Display names by language code (`"it"`, `"en"`, more when the manifest has them); empty for a base pack.
    public let names: [String: String]
    /// The region's bbox; `nil` for a base pack.
    public let bbox: BoundingBox?
    /// Only the configured layers the pack offers.
    public let layers: [Layer: LayerAvailability]
    /// Sum of the available layers' bytes.
    public let totalBytes: Int64
    /// How the installed files compare with the release.
    public let status: PackStatus
}
