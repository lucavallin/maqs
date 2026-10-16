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
        #expect(FileManager.default.fileExists(atPath: store.layout.packsDirectory.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: store.layout.downloadsDirectory.path(percentEncoded: false)))
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
        #expect(!FileManager.default.fileExists(atPath: store.layout.recordURL(.region("test")).path(percentEncoded: false) + ".tmp"))
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
        #expect(!FileManager.default.fileExists(atPath: store.layout.packDirectory(.base("triveneto")).path(percentEncoded: false)))
        #expect(try store.record(for: .base("triveneto")) == nil)
    }

    func place(_ store: PackStore, _ id: PackID, layer: Layer = .trails, name: String, sha: Character = "a", contents: String = "x") throws -> URL {
        let url = store.layout.fileURL(id, layer: layer, sha256: String(repeating: sha, count: 64), fileName: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("the sweep removes files the record does not name and stray temp records, nothing else")
    func sweep() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let id = PackID.region("test")
        try store.write(PackRecord(id: id, release: "data-ci", files: [.trails: [file("keep.sqlite")]]))
        let keep = try place(store, id, name: "keep.sqlite")
        let orphan = try place(store, id, name: "orphan.sqlite")
        let oldVersion = try place(store, id, name: "keep.sqlite", sha: "c")
        let strayTemp = URL(filePath: store.layout.recordURL(id).path(percentEncoded: false) + ".tmp")
        try Data("{".utf8).write(to: strayTemp)
        let download = store.layout.downloadURL(fileName: "partial.bin")
        try Data("p".utf8).write(to: download)
        store.sweep()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: keep.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: orphan.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: oldVersion.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: oldVersion.deletingLastPathComponent().path(percentEncoded: false)))   // emptied directory goes
        #expect(!fm.fileExists(atPath: strayTemp.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: store.layout.recordURL(id).path(percentEncoded: false)))   // pack.json survives
        #expect(fm.fileExists(atPath: download.path(percentEncoded: false)))   // downloads are kept for resume
    }

    @Test("a pack directory without pack.json is deleted")
    func sweepRemovesUnrecordedPack() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let leftover = try place(store, .region("half"), name: "a.sqlite")
        store.sweep()
        #expect(!FileManager.default.fileExists(atPath: store.layout.packDirectory(.region("half")).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
    }

    @Test("a pack directory with an unreadable pack.json is kept")
    func sweepKeepsUnreadablePack() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let id = PackID.region("locked")
        let installed = try place(store, id, name: "a.sqlite")
        try Data("{".utf8).write(to: store.layout.recordURL(id))
        store.sweep()
        #expect(FileManager.default.fileExists(atPath: installed.path(percentEncoded: false)))
    }

    @Test("sweeping one pack leaves the others alone")
    func sweepOnePack() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let one = PackID.region("one"), two = PackID.region("two")
        for id in [one, two] { try store.write(PackRecord(id: id, release: "data-ci", files: [:])) }
        let orphanOne = try place(store, one, name: "o.sqlite")
        let orphanTwo = try place(store, two, name: "o.sqlite")
        store.sweep(one)
        #expect(!FileManager.default.fileExists(atPath: orphanOne.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: orphanTwo.path(percentEncoded: false)))
    }

    @Test("a record naming another pack is corrupt")
    func recordIdentity() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        try store.write(PackRecord(id: .region("a"), release: "data-ci", files: [:]))
        try FileManager.default.createDirectory(at: store.layout.packDirectory(.region("b")), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.layout.recordURL(.region("a")), to: store.layout.recordURL(.region("b")))
        #expect(throws: StorageError.corruptRecord(.region("b"))) { try store.record(for: .region("b")) }
    }

    @Test("pack.json has a pinned shape")
    func goldenRecord() throws {
        let record = PackRecord(id: .region("test"), release: "data-ci", files: [.terrainHD: [file("t.v1.pmtiles")]])
        let json = try #require(String(data: PackStore.makeEncoder().encode(record), encoding: .utf8))
        #expect(json == #"{"files":{"terrain-hd":[{"bytes":3,"dataDate":"1970-01-01T00:00:00Z","fileName":"t.v1.pmtiles","schemaVersion":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]},"id":{"region":{"_0":"test"}},"release":"data-ci"}"#)
        #expect(try PackStore.makeDecoder().decode(PackRecord.self, from: Data(json.utf8)) == record)
    }

    @Test("a root under a path with spaces works end to end")
    func spacesInPath() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url.appending(path: "Application Support/Maqs", directoryHint: .isDirectory))
        let id = PackID.region("test")
        let record = PackRecord(id: id, release: "data-ci", files: [.trails: [file("keep.sqlite")]])
        try store.write(record)
        #expect(try store.record(for: id) == record)
        #expect(store.records() == [id: record])
        let keep = try place(store, id, name: "keep.sqlite")
        let orphan = try place(store, id, name: "orphan.sqlite")
        store.sweep()
        #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))
        try store.removePack(id)
        #expect(try store.record(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.layout.packDirectory(id).path(percentEncoded: false)))
    }

    @Test("moveIntoPlace replaces an existing file atomically")
    func moveIntoPlace() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let destination = store.layout.fileURL(.region("test"), layer: .places, sha256: String(repeating: "a", count: 64), fileName: "p.sqlite")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        let source = store.layout.downloadURL(fileName: "p.sqlite")
        try Data("new".utf8).write(to: source)
        try store.moveIntoPlace(from: source, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("moveIntoPlace creates a missing destination directory")
    func moveCreatesDirectory() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let destination = store.layout.fileURL(.region("new"), layer: .places, sha256: String(repeating: "a", count: 64), fileName: "p.sqlite")
        let source = store.layout.downloadURL(fileName: "p.sqlite")
        try Data("new".utf8).write(to: source)
        try store.moveIntoPlace(from: source, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    }

    @Test("moveIntoPlace from a missing source is a typed error")
    func moveMissingSource() throws {
        let tmp = try TemporaryDirectory()
        let store = try PackStore(root: tmp.url)
        let destination = store.layout.fileURL(.region("new"), layer: .places, sha256: String(repeating: "a", count: 64), fileName: "p.sqlite")
        #expect(throws: StorageError.writeFailed("p.sqlite")) {
            try store.moveIntoPlace(from: store.layout.downloadURL(fileName: "missing.bin"), to: destination)
        }
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
        #expect(overlay.url == store.layout.fileURL(.region("test"), layer: .places, sha256: String(repeating: "b", count: 64), fileName: "test-places.v1.pmtiles"))
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
        try FileManager.default.removeItem(at: document.metaURL)
        #expect(document.read() == nil)   // data without meta
        try document.write(data: Data("{}".utf8), meta: meta)
        try FileManager.default.removeItem(at: document.dataURL)
        #expect(document.read() == nil)   // meta without data
    }
}
