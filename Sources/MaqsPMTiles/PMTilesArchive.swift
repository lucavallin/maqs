import Foundation
import Synchronization

/// A local PMTiles v3 archive, read with positioned reads on one descriptor held open for the archive's lifetime
/// (a removed file stays readable). Every offset and length is checked before it is used.
package final class PMTilesArchive: Sendable {
    private static let maxDirectoryBytes = 16 << 20
    private static let maxTileBytes = 64 << 20
    private static let maxMetadataBytes = 8 << 20
    /// Decoded leaf directories kept at once; a leaf holds at most 16 MiB inflated, so the cache stays bounded.
    private static let leafCacheCapacity = 16

    /// The descriptor, closed when the archive goes away.
    private final class OpenFile: Sendable {
        let descriptor: Int32
        init(descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }

    private struct LeafCache {
        var directories: [UInt64: [DirectoryEntry]] = [:]
        var recency: [UInt64] = []

        mutating func value(for key: UInt64) -> [DirectoryEntry]? {
            guard let entries = directories[key] else { return nil }
            recency.removeAll { $0 == key }
            recency.append(key)
            return entries
        }

        mutating func store(_ entries: [DirectoryEntry], for key: UInt64) {
            directories[key] = entries
            recency.removeAll { $0 == key }
            recency.append(key)
            while recency.count > PMTilesArchive.leafCacheCapacity {
                directories[recency.removeFirst()] = nil
            }
        }
    }

    package let url: URL
    package let header: PMTilesHeader
    /// The metadata's `tile_schema`, when present.
    package let tileSchema: String?
    /// Whether the metadata has a `tile_size` entry, whatever its value.
    package let declaresTileSize: Bool
    /// The metadata's `tile_size` when it is a whole number.
    package let tileSize: Int?
    private let file: OpenFile
    private let rootEntries: [DirectoryEntry]
    private let leafCache = Mutex(LeafCache())

    /// Opens the archive and checks its header, root directory and metadata.
    package init(url: URL) throws(PMTilesReadError) {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadableFile }
        let file = OpenFile(descriptor: descriptor)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else { throw .unreadableFile }
        let headerBytes = try Self.read(file, offset: 0, length: min(Int(status.st_size), PMTilesHeader.size), allowShort: true)
        let header = try PMTilesHeader.parse(headerBytes, fileSize: UInt64(status.st_size))
        let root = try Self.section(file, header: header, offset: header.rootOffset, length: header.rootLength,
                                    cap: Self.maxDirectoryBytes)
        let metadata = try Self.metadata(file, header: header)
        self.url = url
        self.header = header
        self.file = file
        self.rootEntries = try Directory.decode(root)
        self.tileSchema = metadata["tile_schema"] as? String
        self.declaresTileSize = metadata["tile_size"] != nil
        // Bridging is exact: 512.5 or a string is nil here, not truncated to a number.
        self.tileSize = metadata["tile_size"] as? Int
    }

    /// Whether the archive holds tile `z/x/y`. Tiles outside the zoom and coordinate range are absent.
    package func contains(z: Int, x: Int, y: Int) throws(PMTilesReadError) -> Bool {
        try locate(z: z, x: x, y: y) != nil
    }

    /// The decompressed tile, or `nil` when the archive has no such tile.
    package func tile(z: Int, x: Int, y: Int) throws(PMTilesReadError) -> Data? {
        guard let entry = try locate(z: z, x: x, y: y) else { return nil }
        let raw = try Self.read(file, offset: header.tileDataOffset + entry.offset, length: Int(entry.length))
        switch header.tileCompression {
        case .gzip: return try Gzip.inflate(raw, limit: Self.maxTileBytes)
        case .none: return raw
        }
    }

    /// The directory entry of a tile, with its size and position validated; `nil` when absent.
    private func locate(z: Int, x: Int, y: Int) throws(PMTilesReadError) -> DirectoryEntry? {
        guard let tileID = TileID.id(z: z, x: x, y: y) else { return nil }
        guard var entry = Directory.find(rootEntries, tileID: tileID) else { return nil }
        if entry.runLength == 0 {
            let leaf = try leafDirectory(entry)
            guard let inner = Directory.find(leaf, tileID: tileID) else { return nil }
            guard inner.runLength != 0 else { throw .nestedLeafDirectory }
            entry = inner
        }
        // The size check comes first so an absurd length is reported as such, whatever the section sizes say.
        guard entry.length <= UInt64(Self.maxTileBytes) else { throw .sectionTooLarge }
        let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
        guard !overflow, end <= header.tileDataLength else {
            throw .corruptDirectory("tile entry lies beyond the tile data")
        }
        return entry
    }

    private func leafDirectory(_ pointer: DirectoryEntry) throws(PMTilesReadError) -> [DirectoryEntry] {
        if let cached = leafCache.withLock({ $0.value(for: pointer.offset) }) { return cached }
        let (end, overflow) = pointer.offset.addingReportingOverflow(pointer.length)
        guard !overflow, end <= header.leafLength else {
            throw .corruptDirectory("leaf directory lies beyond the leaf section")
        }
        let data = try Self.section(file, header: header, offset: header.leafOffset + pointer.offset,
                                    length: pointer.length, cap: Self.maxDirectoryBytes)
        let entries = try Directory.decode(data)
        leafCache.withLock { $0.store(entries, for: pointer.offset) }
        return entries
    }

    // MARK: reading

    /// A section of the file, inflated when the archive's internal compression says so, with `cap` applied to both sizes.
    private static func section(_ file: OpenFile, header: PMTilesHeader, offset: UInt64, length: UInt64,
                                cap: Int) throws(PMTilesReadError) -> Data {
        guard length <= UInt64(cap) else { throw .sectionTooLarge }
        let raw = try read(file, offset: offset, length: Int(length))
        switch header.internalCompression {
        case .gzip: return try Gzip.inflate(raw, limit: cap)
        case .none: return raw
        }
    }

    /// Only `tile_schema` and `tile_size` are used; anything else in the metadata is ignored.
    private static func metadata(_ file: OpenFile, header: PMTilesHeader) throws(PMTilesReadError) -> [String: Any] {
        guard header.metadataLength > 0 else { return [:] }
        let data = try section(file, header: header, offset: header.metadataOffset, length: header.metadataLength,
                               cap: maxMetadataBytes)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .corruptCompressedData("metadata is not a JSON object")
        }
        return object
    }

    /// `length` bytes at `offset`. A short read means the file shrank or was cut: `truncated`, unless `allowShort`.
    private static func read(_ file: OpenFile, offset: UInt64, length: Int, allowShort: Bool = false) throws(PMTilesReadError) -> Data {
        guard offset <= UInt64(Int64.max) else { throw .truncated }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(length, 1))
        defer { buffer.deallocate() }
        var done = 0
        while done < length {
            let count = pread(file.descriptor, buffer + done, length - done, off_t(offset) + off_t(done))
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadableFile
            }
            if count == 0 { break }
            done += count
        }
        guard done == length || allowShort else { throw .truncated }
        return Data(bytes: buffer, count: done)
    }
}
