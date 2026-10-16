/// Bytes this package keeps on disk.
public struct DiskUsage: Sendable, Equatable {
    /// Installed files per downloaded pack, from the records. Bundled packs are not counted: the app owns those bytes.
    public let bytesByPack: [PackID: Int64]
    /// Partial and completed downloads, and their resume data, waiting in the downloads folder.
    public let downloadsBytes: Int64

    /// Everything above, summed.
    public var total: Int64 { bytesByPack.values.reduce(0, +) + downloadsBytes }
}
