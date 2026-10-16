import Foundation
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct ManifestTests {
    let host = "github.com"

    @Test("the fixture manifest decodes with its regions, base packs, dates and roles")
    func decodesFixture() throws {
        let manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: host)
        #expect(manifest.manifestVersion == 1)
        #expect(manifest.release == "data-ci")
        #expect(manifest.shortbreadVersion == "1.0")
        let test = try #require(manifest.regions.first { $0.id == "test" })
        #expect(test.name["it"] == "Nevegal (test)")
        #expect(test.bbox.count == 4)
        let trails = try #require(test.entries(for: .trails))
        #expect(trails.count == 2)
        #expect(trails.map(\.role).contains("overlay"))
        #expect(trails.allSatisfy { $0.layerSchemaVersion == 1 && $0.sha256.count == 64 })
        let terrain = try #require(test.entries(for: .terrain)?.first)
        #expect(terrain.osmTimestamp == nil)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: terrain.dataDate).hour == 0)
        #expect(manifest.base.count == 1)
        #expect(manifest.base[0].entries(for: .basemap)?.count == 1)
        #expect(manifest.attribution.count >= 3)
    }

    @Test("manifest_version 2 is unsupported and reported with the number")
    func unsupportedVersion() throws {
        let data = try Fixtures.manifestJSON { $0["manifest_version"] = 2 }
        #expect(throws: ManifestError.unsupportedVersion(2)) { try Manifest.decode(data, manifestHost: host) }
    }

    @Test("a missing or non-integer manifest_version is invalid")
    func badVersion() throws {
        let missing = try Fixtures.manifestJSON { $0["manifest_version"] = nil }
        #expect(throws: ManifestError.invalid("manifest_version missing or not an integer")) {
            try Manifest.decode(missing, manifestHost: host)
        }
        let text = try Fixtures.manifestJSON { $0["manifest_version"] = "1" }
        #expect(throws: ManifestError.invalid("manifest_version missing or not an integer")) {
            try Manifest.decode(text, manifestHost: host)
        }
    }

    @Test("a body that is not JSON is reported as such")
    func notJSON() {
        #expect(throws: ManifestError.invalid("not valid JSON")) {
            try Manifest.decode(Data("<html>".utf8), manifestHost: host)
        }
    }

    @Test("a missing required field names its path and leaks no content")
    func missingField() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            regions[0]["bbox"] = nil
            object["regions"] = regions
        }
        do {
            _ = try Manifest.decode(data, manifestHost: host)
            Issue.record("expected an error")
        } catch let ManifestError.invalid(message) {
            #expect(message == "regions.[0]: missing bbox")
        }
    }

    @Test("a wrong type in an entry is invalid")
    func wrongType() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["trails"]![0]["bytes"] = "many"
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[0].bytes: wrong type")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an http entry URL rejects the whole manifest and names the field, not the URL")
    func insecureURL() throws {
        let data = try mutatingEntry("trails", 0) { $0["url"] = ($0["url"] as! String).replacingOccurrences(of: "https://", with: "http://") }
        #expect(throws: ManifestError.insecureURL("regions.[0].layers.trails.[0].url")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an http entry URL under an unknown layer key rejects the manifest")
    func insecureURLUnknownLayer() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            var extra = layers["trails"]![0]
            extra["file"] = "test-roads.v1.sqlite"
            extra["url"] = "http://github.com/x"
            layers["roads"] = [extra]
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        #expect(throws: ManifestError.insecureURL("regions.[0].layers.roads.[0].url")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an entry on another host rejects the whole manifest")
    func foreignHost() throws {
        let data = try mutatingEntry("trails", 0) { $0["url"] = ($0["url"] as! String).replacingOccurrences(of: "github.com", with: "example.org") }
        #expect(throws: ManifestError.foreignHost("regions.[0].layers.trails.[0].url")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a foreign host on a base pack entry rejects the manifest")
    func foreignHostBase() throws {
        let data = try Fixtures.manifestJSON { object in
            var base = object["base"] as! [[String: Any]]
            var layers = base[0]["layers"] as! [String: [[String: Any]]]
            layers["basemap"]![0]["url"] = "https://example.org/x"
            base[0]["layers"] = layers
            object["base"] = base
        }
        #expect(throws: ManifestError.foreignHost("base.[0].layers.basemap.[0].url")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a port or credentials in an entry URL count as a foreign host", arguments: [
        "https://github.com:8443/x", "https://u:p@github.com/x", "https://u@github.com/x",
    ])
    func urlWithPortOrCredentials(url: String) throws {
        let data = try mutatingEntry("trails", 0) { $0["url"] = url }
        #expect(throws: ManifestError.foreignHost("regions.[0].layers.trails.[0].url")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an uppercase scheme and host are accepted")
    func uppercaseURL() throws {
        let data = try mutatingEntry("trails", 0) { $0["url"] = "HTTPS://GitHub.com/x" }
        _ = try Manifest.decode(data, manifestHost: host)
    }

    @Test("a file name that is not a plain versioned name is invalid", arguments: [
        "../x", "a/b.v1.sqlite", "UPPER.v1.sqlite", "noversion.sqlite", "x.v0.sqlite", "",
    ])
    func badFileName(name: String) throws {
        let data = try mutatingEntry("trails", 1) { $0["file"] = name }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[1].file: not a valid file name")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a file name longer than 128 characters is invalid")
    func longFileName() throws {
        let data = try mutatingEntry("trails", 1) { $0["file"] = String(repeating: "a", count: 125) + ".v1.sqlite" }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[1].file: not a valid file name")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a file name used twice is invalid")
    func duplicateFileName() throws {
        let data = try mutatingEntry("trails", 1) { $0["file"] = "test-trails.v1.sqlite" }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[1].file: duplicate file name")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("bytes outside 1...2_040_109_465 are invalid", arguments: [-5, 0, 2_040_109_466])
    func bytesOutOfRange(bytes: Int) throws {
        let data = try mutatingEntry("trails", 0) { $0["bytes"] = bytes }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[0].bytes: out of range")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an attribution URL that is not https is invalid")
    func attributionURL() throws {
        let data = try Fixtures.manifestJSON { object in
            var attribution = object["attribution"] as! [[String: Any]]
            attribution[1]["url"] = "http://example.org/"
            object["attribution"] = attribution
        }
        #expect(throws: ManifestError.invalid("attribution.[1].url: must be https")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a base pack id that is not kebab-case, too long or repeated is invalid")
    func baseIDs() throws {
        let bad = try Fixtures.manifestJSON { object in
            var base = object["base"] as! [[String: Any]]
            base[0]["id"] = "Bad_Id"
            object["base"] = base
        }
        #expect(throws: ManifestError.invalid("base.[0].id: not a valid id")) { try Manifest.decode(bad, manifestHost: host) }
        let long = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            regions[0]["id"] = String(repeating: "a", count: 65)
            object["regions"] = regions
        }
        #expect(throws: ManifestError.invalid("regions.[0].id: not a valid id")) { try Manifest.decode(long, manifestHost: host) }
        let twice = try Fixtures.manifestJSON { object in
            let regions = object["regions"] as! [[String: Any]]
            object["regions"] = regions + regions
        }
        #expect(throws: ManifestError.invalid("regions.[1].id: duplicate id")) { try Manifest.decode(twice, manifestHost: host) }
        let baseTwice = try Fixtures.manifestJSON { object in
            let base = object["base"] as! [[String: Any]]
            object["base"] = base + base
        }
        #expect(throws: ManifestError.invalid("base.[1].id: duplicate id")) { try Manifest.decode(baseTwice, manifestHost: host) }
    }

    @Test("host comparison ignores case")
    func hostCase() throws {
        _ = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "GitHub.com")
    }

    @Test("unknown fields, unknown layer keys and unknown roles are ignored")
    func tolerant() throws {
        let data = try Fixtures.manifestJSON { object in
            object["generator"] = "future"
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            var extra = layers["trails"]![0]
            extra["role"] = "thumbnail"
            extra["file"] = "test-trails-extra.v1.pmtiles"
            layers["trails"]!.append(extra)
            layers["roads"] = layers["trails"]!.enumerated().map { index, entry in
                var copy = entry
                copy["file"] = "test-roads-\(index).v1.sqlite"
                return copy
            }
            regions[0]["layers"] = layers
            regions[0]["mascot"] = "marmot"
            object["regions"] = regions
        }
        let manifest = try Manifest.decode(data, manifestHost: host)
        let region = manifest.regions[0]
        #expect(region.entries(for: .trails)?.count == 3)
        #expect(region.layers["roads"] != nil)
        #expect(Layer(rawValue: "roads") == nil)
    }

    @Test("a malformed data_date is invalid")
    func badDate() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["places"]![0]["data_date"] = "16/10/2026"
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        #expect(throws: ManifestError.invalid("regions.[0].layers.places.[0].data_date: not YYYY-MM-DD")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("an impossible calendar day is invalid")
    func impossibleDate() throws {
        let data = try mutatingEntry("places", 0) { $0["data_date"] = "2026-02-30" }
        #expect(throws: ManifestError.invalid("regions.[0].layers.places.[0].data_date: not YYYY-MM-DD")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    @Test("a timestamp with an offset instead of Z is invalid")
    func offsetTimestamp() throws {
        let created = try Fixtures.manifestJSON { $0["created_at"] = "2026-10-16T10:00:00+02:00" }
        #expect(throws: ManifestError.invalid("created_at: not an ISO 8601 UTC timestamp")) {
            try Manifest.decode(created, manifestHost: host)
        }
        let osm = try mutatingEntry("trails", 0) { $0["osm_timestamp"] = "2026-10-16T10:00:00+02:00" }
        #expect(throws: ManifestError.invalid("regions.[0].layers.trails.[0].osm_timestamp: not an ISO 8601 UTC timestamp")) {
            try Manifest.decode(osm, manifestHost: host)
        }
    }

    @Test("a region id that is not lowercase kebab-case is invalid")
    func badRegionID() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            regions[0]["id"] = "../escape"
            object["regions"] = regions
        }
        #expect(throws: ManifestError.invalid("regions.[0].id: not a valid id")) {
            try Manifest.decode(data, manifestHost: host)
        }
    }

    /// The fixture with one entry of region 0 changed.
    private func mutatingEntry(_ layer: String, _ index: Int, _ change: (inout [String: Any]) -> Void) throws -> Data {
        try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            change(&layers[layer]![index])
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
    }
}
