/// Identifies a downloadable pack: a region from `regions.yaml`, or a base pack (ADR 0007).
public enum PackID: Hashable, Sendable, Codable {
    /// A region, by its `regions.yaml` id (`"veneto"`).
    case region(String)
    /// A base pack, by its id (`"triveneto"`), one basemap file covering several regions at low zoom.
    case base(String)

    /// The directory name under `packs/`: `region-<id>` or `base-<id>`.
    var directoryName: String {
        switch self {
        case .region(let id): "region-\(id)"
        case .base(let id): "base-\(id)"
        }
    }
}
