import Foundation
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct StorageTests {
    func file(_ name: String, sha: Character = "a") -> RecordFile {
        RecordFile(fileName: name, role: nil, schemaVersion: 1, sha256: String(repeating: sha, count: 64), bytes: 3, dataDate: Date(timeIntervalSince1970: 0))
    }

    @Test("creating the store makes the root, packs and downloads directories and excludes the root from backup")
    func creates() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url.appending(path: "Maqs"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.layout.packsDirectory.path(), isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: store.layout.downloadsDirectory.path()))
        let values = try store.layout.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("an unwritable root is a typed error")
    func unwritable() throws {
        let tmp = try TemporaryDirectory()
        let blocker = tmp.url.appending(path: "blocker")
        try Data().write(to: blocker)   // a file where a directory must go
        #expect(throws: StorageError.self) { try PackStore(root: blocker.appending(path: "Maqs")) }
    }

    @Test("a record round-trips and is written atomically next to its files")
    func recordRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let record = PackRecord(id: .region("test"), release: "data-ci", files: [.trails: [file("test-trails.v1.sqlite")]])
        try store.write(record)
        #expect(try store.record(for: .region("test")) == record)
        #expect(store.records() == [.region("test"): record])
        #expect(!FileManager.default.fileExists(atPath: store.layout.recordURL(.region("test")).path() + ".tmp"))
    }

    @Test("a missing record is nil and a corrupt one is a typed error")
    func corrupt() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        #expect(try store.record(for: .region("ghost")) == nil)
        try FileManager.default.createDirectory(at: store.layout.packDirectory(.region("bad")), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.layout.recordURL(.region("bad")))
        #expect(throws: StorageError.corruptRecord(.region("bad"))) { try store.record(for: .region("bad")) }
        #expect(store.records().isEmpty)   // skipped, not thrown, when listing
    }

    @Test("removing a pack deletes its directory")
    func remove() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let record = PackRecord(id: .base("triveneto"), release: "data-ci", files: [:])
        try store.write(record)
        try store.removePack(.base("triveneto"))
        #expect(!FileManager.default.fileExists(atPath: store.layout.packDirectory(.base("triveneto")).path()))
        #expect(try store.record(for: .base("triveneto")) == nil)
    }

    @Test("the sweep removes files the record does not name and stray temp records, nothing else")
    func sweep() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let id = PackID.region("test")
        let record = PackRecord(id: id, release: "data-ci", files: [.trails: [file("keep.sqlite")]])
        try store.write(record)
        let keep = store.layout.fileURL(id, layer: .trails, fileName: "keep.sqlite")
        let orphan = store.layout.fileURL(id, layer: .trails, fileName: "orphan.sqlite")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("k".utf8).write(to: keep)
        try Data("o".utf8).write(to: orphan)
        let strayTemp = URL(filePath: store.layout.recordURL(id).path() + ".tmp")
        try Data("{".utf8).write(to: strayTemp)
        let download = store.layout.downloadURL(fileName: "partial.bin")
        try Data("p".utf8).write(to: download)
        store.sweep()
        #expect(FileManager.default.fileExists(atPath: keep.path()))
        #expect(!FileManager.default.fileExists(atPath: orphan.path()))
        #expect(!FileManager.default.fileExists(atPath: strayTemp.path()))
        #expect(FileManager.default.fileExists(atPath: download.path()))   // downloads are kept for resume
    }

    @Test("moveIntoPlace replaces an existing file atomically")
    func moveIntoPlace() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let destination = store.layout.fileURL(.region("test"), layer: .places, fileName: "p.sqlite")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        let source = store.layout.downloadURL(fileName: "p.sqlite")
        try Data("new".utf8).write(to: source)
        try store.moveIntoPlace(from: source, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path()))
    }

    @Test("installedPack resolves file URLs under the pack directory")
    func installedPack() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let record = PackRecord(id: .region("test"), release: "data-ci", files: [.places: [file("test-places.v1.sqlite"), RecordFile(fileName: "test-places.v1.pmtiles", role: "overlay", schemaVersion: 1, sha256: String(repeating: "b", count: 64), bytes: 5, dataDate: Date(timeIntervalSince1970: 0))]])
        let pack = store.installedPack(from: record)
        #expect(pack.id == .region("test"))
        #expect(pack.bundled == false)
        #expect(pack.bytes == 8)
        let overlay = try #require(pack.files[.places]?.first { $0.role == "overlay" })
        #expect(overlay.url == store.layout.fileURL(.region("test"), layer: .places, fileName: "test-places.v1.pmtiles"))
        #expect(overlay.sha256 == String(repeating: "b", count: 64))
    }

    @Test("a cached document stores data and meta and reads nil when either is missing")
    func cachedDocument() throws {
        let tmp = try TemporaryDirectory()
        let document = StorageLayout(root: tmp.url).manifest
        #expect(document.read() == nil)
        let meta = CachedDocument.Meta(etag: "\"e\"", fetchedAt: Date(timeIntervalSince1970: 100))
        try document.write(data: Data("{}".utf8), meta: meta)
        let read = try #require(document.read())
        #expect(read.data == Data("{}".utf8))
        #expect(read.meta == meta)
        try document.touch(fetchedAt: Date(timeIntervalSince1970: 200))
        #expect(document.read()?.meta.fetchedAt == Date(timeIntervalSince1970: 200))
        #expect(document.read()?.meta.etag == "\"e\"")
    }
}
