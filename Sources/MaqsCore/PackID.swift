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

    /// Whether the id follows the manifest's rule, so it can name a directory: lowercase kebab-case
    /// (`[a-z0-9]+(-[a-z0-9]+)*`), at most 64 characters. Every public entry point checks it before the id reaches a path.
    var isValid: Bool {
        switch self {
        case .region(let id), .base(let id): Self.isValidID(id)
        }
    }

    /// The one implementation of the id rule; the manifest validates its ids with it too.
    static func isValidID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 64 else { return false }
        // Scalar by scalar, so a combining mark or a non-ASCII letter can never pass as part of a range.
        var afterHyphen = true   // at the start, too: an id cannot begin with a hyphen
        for scalar in scalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                afterHyphen = false
            case "-":
                if afterHyphen { return false }
                afterHyphen = true
            default:
                return false
            }
        }
        return !afterHyphen
    }
}
