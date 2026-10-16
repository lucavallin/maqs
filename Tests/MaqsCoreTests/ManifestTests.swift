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
        #expect(throws: ManifestError.self) { try Manifest.decode(text, manifestHost: host) }
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
        #expect(throws: ManifestError.self) { try Manifest.decode(data, manifestHost: host) }
    }

    @Test("an http entry URL rejects the whole manifest")
    func insecureURL() throws {
        let data = try rewritingFirstTrailsURL { $0.replacingOccurrences(of: "https://", with: "http://") }
        #expect(throws: ManifestError.self) { try Manifest.decode(data, manifestHost: host) }
        do { _ = try Manifest.decode(data, manifestHost: host) } catch let error as ManifestError {
            guard case .insecureURL = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test("an entry on another host rejects the whole manifest")
    func foreignHost() throws {
        let data = try rewritingFirstTrailsURL { $0.replacingOccurrences(of: "github.com", with: "example.org") }
        do { _ = try Manifest.decode(data, manifestHost: host); Issue.record("expected an error") }
        catch let error as ManifestError {
            guard case .foreignHost(let url) = error else { Issue.record("wrong error \(error)"); return }
            #expect(url.contains("example.org"))
        }
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
            layers["trails"]!.append(extra)
            layers["roads"] = layers["trails"]
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
        #expect(throws: ManifestError.self) { try Manifest.decode(data, manifestHost: host) }
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

    private func rewritingFirstTrailsURL(_ transform: (String) -> String) throws -> Data {
        try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["trails"]![0]["url"] = transform(layers["trails"]![0]["url"] as! String)
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
    }
}
