import Foundation
import Testing
@testable import MaqsCore

@Suite struct MaqsConfigurationTests {
    @Test("defaults point at the repository's manifest and sources on GitHub")
    func defaults() {
        let configuration = MaqsConfiguration(layers: [.trails], userAgent: "Test/1")
        #expect(configuration.manifestURL.host() == "github.com")
        #expect(configuration.manifestURL.path().hasSuffix("/releases/latest/download/manifest.json"))
        #expect(configuration.sourcesURL.host() == "raw.githubusercontent.com")
        #expect(configuration.onlineTiles)
        #expect(configuration.backgroundSessionIdentifier == nil)
        #expect(configuration.catalogMaxAge == .seconds(86_400))
    }

    @Test("the full User-Agent is the app string followed by the package token")
    func userAgent() {
        let configuration = MaqsConfiguration(layers: [], userAgent: "Test/1 (iOS)")
        #expect(configuration.fullUserAgent == "Test/1 (iOS) Maqs/\(MaqsVersion.string)")
    }

    @Test("pack ids map to stable directory names")
    func directoryNames() {
        #expect(PackID.region("veneto").directoryName == "region-veneto")
        #expect(PackID.base("triveneto").directoryName == "base-triveneto")
    }

    @Test("pack ids that follow the manifest rule are valid",
          arguments: ["test", "veneto", "friuli-venezia-giulia", "a", "a1-b2", String(repeating: "a", count: 64)])
    func validIDs(_ id: String) {
        #expect(PackID.region(id).isValid)
        #expect(PackID.base(id).isValid)
    }

    @Test("pack ids that break the manifest rule are invalid",
          arguments: ["triveneto/../../victim", "../victim", "..", ".", "", "Triveneto", "a b", "a_b", "a.b", "-a", "a-",
                      "a--b", "é", "a\u{301}", String(repeating: "a", count: 65)])
    func invalidIDs(_ id: String) {
        #expect(!PackID.region(id).isValid)
        #expect(!PackID.base(id).isValid)
    }

    @Test("layer raw values are the manifest keys")
    func layerKeys() {
        #expect(Layer.terrainHD.rawValue == "terrain-hd")
        #expect(Layer(rawValue: "trails") == .trails)
    }
}
