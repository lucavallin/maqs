import Foundation
@testable import MaqsCore
import Testing

@testable import MaqsUI

@Suite struct CreditsTests {
    private func entry(_ text: String, _ layers: [Layer]) -> Attribution {
        Attribution(text: text, licence: "x", url: URL(string: "https://example.org/\(layers[0].rawValue)")!, layers: layers)
    }

    private var manifest: [Attribution] {
        [
            entry("© OpenStreetMap contributors", [.basemap, .trails, .places]),
            entry("CC BY 4.0 ESA WorldCover 2021", [.basemap]),
            entry("© Mapterhorn", [.terrain]),
        ]
    }

    @Test func basemapOnlineShowsTheProviderStringsWithoutUrl() {
        let result = Credits.credits(
            drawn: [.basemap], online: [.basemap: ["VersaTiles"]], manifest: manifest, installed: [])
        #expect(result == [MapCredit(text: "VersaTiles", url: nil)])
    }

    @Test func basemapAndTerrainOnlineComeInLayerOrder() {
        let result = Credits.credits(
            drawn: [.terrain, .basemap],
            online: [.basemap: ["© OpenStreetMap contributors"], .terrain: ["© Mapterhorn"]],
            manifest: manifest, installed: [])
        #expect(result.map(\.text) == ["© OpenStreetMap contributors", "© Mapterhorn"])
    }

    @Test func installedBasemapWithTrailsAndPlacesListsManifestEntriesOnce() {
        let result = Credits.credits(
            drawn: [.basemap, .trails, .places], online: [:], manifest: manifest, installed: [.basemap, .trails, .places])
        #expect(result.map(\.text) == ["© OpenStreetMap contributors", "CC BY 4.0 ESA WorldCover 2021"])
        #expect(result.allSatisfy { $0.url != nil })
    }

    @Test func aStringOnlineAndInTheManifestAppearsOnceWithTheManifestUrl() {
        let result = Credits.credits(
            drawn: [.basemap], online: [.basemap: ["© OpenStreetMap contributors"]], manifest: manifest,
            installed: [.basemap])
        #expect(result.filter { $0.text == "© OpenStreetMap contributors" }.count == 1)
        #expect(result.first?.url == URL(string: "https://example.org/basemap"))
    }

    @Test func undrawnLayersAndUninstalledDataAddNothing() {
        let result = Credits.credits(
            drawn: [.basemap], online: [.terrain: ["© Mapterhorn"]], manifest: manifest, installed: [.terrain])
        #expect(result.isEmpty)
    }

    /// Terrain drawn from an online source that names no credit and from a pack the manifest has no entry for: it is
    /// reported, and the basemap's credit is still listed.
    @Test func aDrawnLayerWithNoCreditIsReportedAndTheOthersAreStillListed() {
        let online: [Layer: [String]] = [.basemap: ["VersaTiles"], .terrain: []]
        let installed: Set<Layer> = [.terrain]
        #expect(Credits.uncredited(drawn: [.basemap, .terrain], online: online, manifest: [], installed: installed)
            == [.terrain])
        #expect(Credits.credits(drawn: [.basemap, .terrain], online: online, manifest: [], installed: installed)
            == [MapCredit(text: "VersaTiles", url: nil)])
    }

    @Test func noLayerIsReportedWhenEveryDrawnLayerHasACredit() {
        let result = Credits.uncredited(
            drawn: [.basemap, .terrain, .trails], online: [.basemap: ["VersaTiles"]], manifest: manifest,
            installed: [.terrain, .trails])
        #expect(result.isEmpty)
    }
}
