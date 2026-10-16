import Foundation

/// Owns the storage root: creates it, keeps it out of backups, reads and writes `pack.json`, moves files into place.
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
            throw StorageError.cannotCreateDirectory(root.lastPathComponent)
        }
    }

    /// `nil` when nothing is installed; `corruptRecord` when `pack.json` exists but cannot be read.
    func record(for id: PackID) throws -> PackRecord? {
        let url = layout.recordURL(id)
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(PackRecord.self, from: data) else {
            throw StorageError.corruptRecord(id)
        }
        return record
    }

    /// Every readable record. A corrupt one is logged and skipped so the rest of the catalog still works.
    func records() -> [PackID: PackRecord] {
        var result: [PackID: PackRecord] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.packsDirectory.path())) ?? []
        for name in names {
            let id: PackID
            if name.hasPrefix("region-") { id = .region(String(name.dropFirst("region-".count))) }
            else if name.hasPrefix("base-") { id = .base(String(name.dropFirst("base-".count))) }
            else { continue }
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
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed("pack.json")
        }
    }

    /// Deletes `pack.json` first, so no reader finds a half-deleted pack, then the directory.
    func removePack(_ id: PackID) throws {
        let record = layout.recordURL(id)
        do {
            if FileManager.default.fileExists(atPath: record.path()) { try FileManager.default.removeItem(at: record) }
            if FileManager.default.fileExists(atPath: layout.packDirectory(id).path()) {
                try FileManager.default.removeItem(at: layout.packDirectory(id))
            }
        } catch {
            throw StorageError.writeFailed(id.directoryName)
        }
    }

    /// Moves a verified download over the previous file of that layer in one `rename(2)`, which replaces atomically.
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
        guard result == 0 else { throw StorageError.writeFailed(destination.lastPathComponent) }
    }

    func installedPack(from record: PackRecord) -> InstalledPack {
        var files: [Layer: [InstalledFile]] = [:]
        for (layer, recorded) in record.files {
            files[layer] = recorded.map {
                InstalledFile(url: layout.fileURL(record.id, layer: layer, fileName: $0.fileName), role: $0.role,
                              schemaVersion: $0.schemaVersion, sha256: $0.sha256, bytes: $0.bytes, dataDate: $0.dataDate)
            }
        }
        return InstalledPack(id: record.id, release: record.release, files: files, bundled: false)
    }

    /// Removes, under each pack directory, files its record does not name and stray `pack.json.tmp` files.
    /// `downloads/` is left alone: partial and completed downloads are reused after a hash check.
    func sweep() {
        let fm = FileManager.default
        for (id, record) in records() {
            // The enumerator reports symlink-resolved paths (/private/var on macOS), so both sides are resolved the same way.
            let directory = layout.packDirectory(id).resolvingSymlinksInPath()
            let named = Set(record.files.flatMap { layer, files in
                files.map { directory.appending(path: layer.rawValue, directoryHint: .isDirectory).appending(path: $0.fileName).path() }
            })
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if url.lastPathComponent == "pack.json" { continue }
                if url.lastPathComponent == "pack.json.tmp" || !named.contains(url.resolvingSymlinksInPath().path()) {
                    try? fm.removeItem(at: url)
                    logger.info("swept orphan \(url.lastPathComponent, privacy: .public)")
                }
            }
        }
    }
}
