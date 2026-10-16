import Foundation

/// One installed file as `pack.json` records it. Paths are relative: the container moves between launches.
struct RecordFile: Codable, Sendable, Equatable {
    let fileName: String
    let role: String?
    let schemaVersion: Int
    let sha256: String
    let bytes: Int64
    let dataDate: Date
}

/// `pack.json`: what is installed for one pack. Readers trust only files this names.
struct PackRecord: Codable, Sendable, Equatable {
    let id: PackID
    var release: String
    var files: [Layer: [RecordFile]]
}

/// One file of an installed pack, ready for `MaqsTerrain` and `MaqsData` to open.
public struct InstalledFile: Sendable, Equatable {
    /// The file on disk.
    public let url: URL
    /// `nil` for the main file, `"overlay"` for the tile file of trails and places.
    public let role: String?
    /// The `layer_schema_version` the file was written with.
    public let schemaVersion: Int
    /// The manifest's SHA-256, verified at install; `nil` for a file the app bundled itself.
    public let sha256: String?
    /// The file size in bytes.
    public let bytes: Int64
    /// The `data_date` of the entry; `nil` for a bundled file.
    public let dataDate: Date?
}

/// An installed pack: the files per layer, as recorded in `pack.json` or registered by the app.
public struct InstalledPack: Sendable, Equatable {
    /// The pack this record belongs to.
    public let id: PackID
    /// The data release the files came from, or `"bundled"`.
    public let release: String
    /// The installed files per layer.
    public let files: [Layer: [InstalledFile]]
    /// `true` when the app registered the file from its own bundle (``Maqs/registerBundledBasePack(id:basemap:)``).
    public let bundled: Bool
    /// Bytes on disk, summed over every file.
    public var bytes: Int64 { files.values.flatMap { $0 }.reduce(0) { $0 + $1.bytes } }
}
