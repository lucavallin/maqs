/// The client half of the compatibility rule in `docs/data-format.md`: which `layer_schema_version`s this
/// package reads, and which entries of a layer a client takes.
enum ReadableVersions {
    /// Bump a layer's set when a reader for a new version ships; drop a version when its reader is removed.
    static let table: [Layer: Set<Int>] = Dictionary(uniqueKeysWithValues: Layer.allCases.map { ($0, Set([1])) })

    /// Roles this package knows. `nil` is the main file; `overlay` the tile file of trails and places.
    static let knownRoles: Set<String> = ["overlay"]

    enum Selection: Equatable, Sendable {
        /// The newest version the package reads, with every file of that version.
        case readable(version: Int, files: [ManifestEntry])
        /// No offered version is readable; the versions seen, newest first.
        case unreadable(offeredVersions: [Int])
    }

    /// `nil` when the layer offers nothing this package recognises (no entries, or only unknown roles).
    static func select(_ entries: [ManifestEntry], for layer: Layer, readable: Set<Int>? = nil) -> Selection? {
        let readable = readable ?? table[layer] ?? []
        let known = entries.filter { $0.role == nil || knownRoles.contains($0.role ?? "") }
        let versions = Set(known.map(\.layerSchemaVersion)).sorted(by: >)
        guard let newest = versions.first(where: readable.contains) else {
            return versions.isEmpty ? nil : .unreadable(offeredVersions: versions)
        }
        return .readable(version: newest, files: known.filter { $0.layerSchemaVersion == newest })
    }
}
