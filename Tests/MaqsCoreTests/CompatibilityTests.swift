import Foundation
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct CompatibilityTests {
    func entry(_ version: Int, role: String? = nil, file: String = "x") -> ManifestEntry {
        ManifestEntry(layerSchemaVersion: version, file: "\(file).v\(version)", url: URL(string: "https://github.com/f")!,
                      bytes: 10, sha256: String(repeating: "a", count: 64), dataDate: Date(timeIntervalSince1970: 0),
                      osmTimestamp: nil, role: role)
    }

    @Test("every layer has a readable-version entry, and today it is version 1")
    func table() {
        for layer in Layer.allCases { #expect(ReadableVersions.table[layer] == [1]) }
    }

    @Test("the newest readable version wins and takes all its files")
    func newestReadable() {
        let entries = [entry(3), entry(2), entry(2, role: "overlay"), entry(1)]
        let selection = ReadableVersions.select(entries, for: .trails, readable: [1, 2])
        #expect(selection == .readable(version: 2, files: [entry(2), entry(2, role: "overlay")]))
    }

    @Test("order in the manifest does not matter")
    func unsorted() {
        let selection = ReadableVersions.select([entry(1), entry(2)], for: .places, readable: [1, 2])
        #expect(selection == .readable(version: 2, files: [entry(2)]))
    }

    @Test("no readable version is unreadable with the offered versions, newest first")
    func unreadable() {
        let selection = ReadableVersions.select([entry(2), entry(3)], for: .curvature, readable: [1])
        #expect(selection == .unreadable(offeredVersions: [3, 2]))
    }

    @Test("entries with an unknown role are ignored, and a layer with only unknown roles offers nothing")
    func unknownRole() {
        let known = ReadableVersions.select([entry(1), entry(1, role: "thumbnail")], for: .trails)
        #expect(known == .readable(version: 1, files: [entry(1)]))
        let onlyUnknown = ReadableVersions.select([entry(1, role: "thumbnail")], for: .trails)
        #expect(onlyUnknown == nil)
    }

    @Test("an empty entry list means the layer is not offered")
    func empty() {
        #expect(ReadableVersions.select([], for: .terrainHD) == nil)
    }

    @Test("the fixture's trails layer selects version 1 with the sqlite and the overlay")
    func fixture() throws {
        let manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "github.com")
        let region = try #require(manifest.regions.first)
        guard case .readable(let version, let files)? = ReadableVersions.select(region.entries(for: .trails) ?? [], for: .trails) else {
            Issue.record("expected readable"); return
        }
        #expect(version == 1)
        #expect(files.count == 2)
    }
}
