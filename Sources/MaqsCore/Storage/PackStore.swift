import Foundation

/// Owns the storage root: creates it, keeps it out of backups, reads and writes `pack.json`, moves files into place.
///
/// Paths handed to string-path APIs always use `path(percentEncoded: false)`: `URL.path()` percent-encodes
/// (`Application%20Support`) and would miss real files.
struct PackStore: Sendable {
    let layout: StorageLayout

    init(root: URL) throws {
        layout = StorageLayout(root: root)
        for directory in [layout.root, layout.packsDirectory, layout.downloadsDirectory] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StorageError.cannotCreateDirectory(directory.lastPathComponent)
            }
        }
        var root = layout.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try root.setResourceValues(values)
        } catch {
            throw StorageError.writeFailed(root.lastPathComponent)
        }
    }

    /// The `pack.json` encoding. Sorted keys and ISO 8601 dates keep the file stable and diffable.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `nil` when nothing is installed; `corruptRecord` when `pack.json` exists but cannot be read or names another pack.
    func record(for id: PackID) throws -> PackRecord? {
        let url = layout.recordURL(id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let record = try? Self.makeDecoder().decode(PackRecord.self, from: data),
              record.id == id
        else {
            throw StorageError.corruptRecord(id)
        }
        return record
    }

    /// Every readable record. A corrupt one is logged and skipped so the rest of the catalog still works.
    func records() -> [PackID: PackRecord] {
        var result: [PackID: PackRecord] = [:]
        for (id, name) in packDirectories() {
            do {
                if let record = try record(for: id) { result[id] = record }
            } catch {
                logger.error("pack record unreadable: \(name, privacy: .public)")
            }
        }
        return result
    }

    /// Writes `pack.json` atomically. Call it last, after every file it names is in place.
    func write(_ record: PackRecord) throws {
        let url = layout.recordURL(record.id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.makeEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed("pack.json")
        }
    }

    /// Deletes `pack.json` first, so no reader finds a half-deleted pack, then the directory.
    func removePack(_ id: PackID) throws {
        let record = layout.recordURL(id)
        let directory = layout.packDirectory(id)
        do {
            if FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) { try FileManager.default.removeItem(at: record) }
            if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            throw StorageError.writeFailed(id.directoryName)
        }
    }

    /// Moves a verified download into place in one `rename(2)`, which replaces an existing file atomically.
    func moveIntoPlace(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw StorageError.cannotCreateDirectory(destination.deletingLastPathComponent().lastPathComponent)
        }
        let result: Int32 = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return -1 }
                return rename(from, to)
            }
        }
        guard result == 0 else {
            logger.error("rename failed, errno \(errno, privacy: .public)")
            throw StorageError.writeFailed(destination.lastPathComponent)
        }
    }

    func installedPack(from record: PackRecord) -> InstalledPack {
        var files: [Layer: [InstalledFile]] = [:]
        for (layer, recorded) in record.files {
            files[layer] = recorded.map {
                InstalledFile(url: layout.fileURL(record.id, layer: layer, sha256: $0.sha256, fileName: $0.fileName), role: $0.role,
                              schemaVersion: $0.schemaVersion, sha256: $0.sha256, bytes: $0.bytes, dataDate: $0.dataDate)
            }
        }
        return InstalledPack(id: record.id, release: record.release, files: files, bundled: false)
    }

    /// Cleans every pack directory. Call it at launch only: it must not race an install.
    func sweep() {
        for (id, _) in packDirectories() { sweep(id) }
    }

    /// Cleans one pack directory; the installer calls it after that pack's own install.
    ///
    /// - No `pack.json` at all: an interrupted first install or removal, so the directory goes.
    /// - An unreadable `pack.json`: the directory stays (data protection can hide a file before first unlock).
    /// - Otherwise every regular file the record does not name goes, then directories left empty.
    ///
    /// `downloads/` is left alone: partial and completed downloads are reused after a hash check.
    func sweep(_ id: PackID) {
        let fm = FileManager.default
        let directory = layout.packDirectory(id)
        guard fm.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        if !fm.fileExists(atPath: layout.recordURL(id).path(percentEncoded: false)) {
            remove(directory)
            return
        }
        let record: PackRecord
        do {
            guard let found = try self.record(for: id) else { return }
            record = found
        } catch {
            logger.error("sweep skipped, pack record unreadable: \(id.directoryName, privacy: .public)")
            return
        }
        // The enumerator reports symlink-resolved paths, so both sides are resolved the same way.
        let named = Set(record.files.flatMap { layer, files in
            files.map { Self.resolved(layout.fileURL(id, layer: layer, sha256: $0.sha256, fileName: $0.fileName)) }
        })
        let recordPath = Self.resolved(layout.recordURL(id))
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: resolvedDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true { directories.append(url); continue }
            guard values?.isRegularFile == true else { continue }
            let path = Self.resolved(url)
            if path == recordPath || named.contains(path) { continue }
            remove(url)
        }
        for url in directories.reversed() where url != resolvedDirectory {
            if let contents = try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false)), contents.isEmpty {
                remove(url)
            }
        }
    }

    private static func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.info("swept \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("sweep could not remove \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func packDirectories() -> [(PackID, String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.packsDirectory.path(percentEncoded: false))) ?? []
        return names.compactMap { name in
            if name.hasPrefix("region-") { return (.region(String(name.dropFirst("region-".count))), name) }
            if name.hasPrefix("base-") { return (.base(String(name.dropFirst("base-".count))), name) }
            return nil
        }
    }
}
