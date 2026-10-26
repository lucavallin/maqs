import Foundation
import Testing
@testable import MaqsTerrain

@Suite struct OnlineTerrainSourceTests {
    /// One set of source values, valid unless a test changes one of them.
    struct Candidate: Sendable, CustomTestStringConvertible {
        let label: String
        var tiles = "https://tiles.example.org/{z}/{x}/{y}"
        var format = "webp"
        var tileSize = 512
        var minZoom = 0
        var maxZoom = 12
        var testDescription: String { label }

        func make() throws(TerrainError) -> OnlineTerrainSource {
            try OnlineTerrainSource(tiles: tiles, format: format, tileSize: tileSize, minZoom: minZoom, maxZoom: maxZoom)
        }
    }

    static let invalid: [Candidate] = [
        Candidate(label: "an http template", tiles: "http://tiles.example.org/{z}/{x}/{y}"),
        Candidate(label: "no host", tiles: "https:///{z}/{x}/{y}"),
        Candidate(label: "credentials", tiles: "https://user:pw@tiles.example.org/{z}/{x}/{y}"),
        Candidate(label: "no {z}", tiles: "https://tiles.example.org/{x}/{y}"),
        Candidate(label: "no {x}", tiles: "https://tiles.example.org/{z}/{y}"),
        Candidate(label: "no {y}", tiles: "https://tiles.example.org/{z}/{x}"),
        Candidate(label: "another placeholder", tiles: "https://tiles.example.org/{s}/{z}/{x}/{y}"),
        Candidate(label: "not a URL", tiles: " https://tiles.example.org/{z}/{x}/{y}"),
        Candidate(label: "a placeholder in the host", tiles: "https://{z}.example.org/{x}/{y}"),
        Candidate(label: "a placeholder joined to the host", tiles: "https://tiles.example.org{x}/{z}/{y}"),
        Candidate(label: "a placeholder in the port", tiles: "https://tiles.example.org:8{z}/{x}/{y}"),
        Candidate(label: "format jpg", format: "jpg"),
        Candidate(label: "tile size 300", tileSize: 300),
        Candidate(label: "minZoom -1", minZoom: -1),
        Candidate(label: "minZoom above maxZoom", minZoom: 13, maxZoom: 12),
        Candidate(label: "maxZoom 23", maxZoom: 23),
    ]

    @Test func aValidSourceIsAccepted() throws {
        let source = try Candidate(label: "valid").make()
        #expect(source.tiles == "https://tiles.example.org/{z}/{x}/{y}")
        #expect(source.format == "webp")
        #expect(source.tileSize == 512)
        #expect(source.minZoom == 0)
        #expect(source.maxZoom == 12)
    }

    @Test func pngAnd256PixelTilesAreAccepted() throws {
        let source = try Candidate(label: "png", format: "png", tileSize: 256, minZoom: 3, maxZoom: 22).make()
        #expect(source.format == "png")
        #expect(source.tileSize == 256)
    }

    @Test(arguments: invalid)
    func anInvalidValueIsRejected(_ candidate: Candidate) {
        do {
            _ = try candidate.make()
            Issue.record("\(candidate.label) was accepted")
        } catch {
            guard case .invalidConfiguration = error else {
                Issue.record("\(candidate.label): expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

    @Test func urlSubstitutesAllThreePlaceholders() throws {
        let source = try Candidate(label: "valid").make()
        #expect(source.url(for: TileKey(z: 12, x: 2187, y: 1455)) == URL(string: "https://tiles.example.org/12/2187/1455"))
    }

    @Test func urlSubstitutesPlaceholdersInAnyPosition() throws {
        let source = try Candidate(label: "query", tiles: "https://tiles.example.org/t?y={y}&x={x}&z={z}").make()
        #expect(source.url(for: TileKey(z: 7, x: 68, y: 45)) == URL(string: "https://tiles.example.org/t?y=45&x=68&z=7"))
    }
}
