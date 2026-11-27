import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct PlaceSearchTests {
    private static let point = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)

    private func fixturePlaces() throws -> Places {
        try Places(files: [Fixtures.url("test/test-places.v1.sqlite")])
    }

    private func reader(_ rows: [PlaceRow], in directory: TemporaryDirectory) throws -> Places {
        let url = directory.url.appending(path: "places.sqlite")
        try LayerFileWriter.places(rows, to: url)
        return try Places(files: [url])
    }

    // MARK: Matching

    @Test("the last word is a prefix")
    func prefix() async throws {
        let found = try await fixturePlaces().search("cast")
        #expect(found.map(\.name) == ["Castoi", "Castion"])
    }

    @Test("every word must match, the last as a prefix")
    func wordsAnd() async throws {
        let places = try fixturePlaces()
        #expect(try await places.search("col can").map(\.name) == ["Col Canil"])
        #expect(try await places.search("piano nev").map(\.name) == ["Piano Nevegal"])
    }

    @Test("case is ignored")
    func caseIgnored() async throws {
        #expect(try await fixturePlaces().search("COL CANIL").map(\.featureID) == [22])
    }

    @Test("accents are ignored, in the text and in the names")
    func accentsIgnored() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            PlaceRow(id: 1, name: "Cima Pèlf", coordinate: Self.point),
            PlaceRow(id: 2, name: "Cima Pelmo", coordinate: Self.point),
        ], in: directory)
        #expect(try await places.search("pelf").map(\.featureID) == [1])
        #expect(try await places.search("PÈLF").map(\.featureID) == [1])
        #expect(try await places.search("cima pél").map(\.featureID) == [1, 2])
    }

    @Test("a name in another language matches too")
    func localizedNames() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            PlaceRow(id: 1, name: "Tre Cime di Lavaredo", nameDE: "Drei Zinnen", coordinate: Self.point),
            PlaceRow(id: 2, name: "Triglav", nameIT: "Tricorno", coordinate: Self.point),
        ], in: directory)
        #expect(try await places.search("drei zin").map(\.featureID) == [1])
        #expect(try await places.search("tricorno").map(\.featureID) == [2])
    }

    @Test("ss finds ß and ß finds ss, as German writes either and the index keeps ß")
    func sharpS() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            PlaceRow(id: 1, name: "Großglockner", coordinate: Self.point),
            PlaceRow(id: 2, name: "Weissmies", coordinate: Self.point),
        ], in: directory)
        #expect(try await places.search("grossglockner").map(\.featureID) == [1])
        #expect(try await places.search("GROSSGL").map(\.featureID) == [1])
        #expect(try await places.search("großglockner").map(\.featureID) == [1])
        #expect(try await places.search("weiß").map(\.featureID) == [2])
    }

    @Test("a word with ss or ß is an OR of both spellings; other words are left as they are")
    func sharpSExpression() {
        #expect(FullText.matchExpression(["monte", "gross"]) == #""monte" ("gross"* OR "groß"*)"#)
        #expect(FullText.matchExpression(["weiß", "kugel"]) == #"("weiß" OR "weiss") "kugel"*"#)
        #expect(FullText.matchExpression(["col"]) == #""col"*"#)
    }

    // MARK: Order and limits

    @Test("results come highest rank_score first, ties by feature id")
    func order() async throws {
        let found = try await fixturePlaces().search("col")
        #expect(found.map(\.featureID) == [22, 19, 15])
        #expect(try await fixturePlaces().search("nevegal").map(\.featureID) == [12, 20])
    }

    @Test("kinds keeps only those kinds; an empty set finds nothing")
    func kinds() async throws {
        let places = try fixturePlaces()
        #expect(try await places.search("c", kinds: [.village]).map(\.featureID) == [1, 2, 11, 6])
        #expect(try await places.search("c", kinds: [.peak, .village]).map(\.featureID) == [22, 1, 2, 11, 19, 15, 6])
        #expect(try await places.search("c", kinds: []).isEmpty)
    }

    @Test("the limit keeps the most notable")
    func limit() async throws {
        #expect(try await fixturePlaces().search("c", limit: 2).map(\.featureID) == [22, 1])
    }

    @Test("a limit within 1...500 is accepted; outside it throws before any file is read")
    func limitRange() async throws {
        let places = try fixturePlaces()
        #expect(try await places.search("col", limit: 1).count == 1)
        #expect(try await places.search("col", limit: 500).count == 3)
        for limit in [0, -1, 501] {
            do {
                _ = try await places.search("col", limit: limit)
                Issue.record("limit \(limit) was accepted")
            } catch {
                guard case .invalidInput = error else {
                    Issue.record("limit \(limit): unexpected \(error)")
                    continue
                }
            }
        }
    }

    @Test("blank text finds nothing")
    func blankText() async throws {
        let places = try fixturePlaces()
        for text in ["", " ", "\n\t "] {
            #expect(try await places.search(text).isEmpty)
        }
    }

    @Test("with no files a search answers empty")
    func noFiles() async throws {
        #expect(try await Places(files: []).search("col").isEmpty)
    }

    @Test("a place in two files comes back once, from the first")
    func duplicateAcrossFiles() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.places([PlaceRow(id: 1, name: "Col Alto", coordinate: Self.point)], to: first, region: "alpha")
        try LayerFileWriter.places([
            PlaceRow(id: 2, osmID: 1, name: "Col Alto", coordinate: Self.point),
            PlaceRow(id: 9, name: "Col Basso", coordinate: Self.point),
        ], to: second, region: "beta")
        let found = try await Places(files: [first, second]).search("col")
        #expect(found.map(\.region) == ["alpha", "beta"])
        #expect(found.map(\.id) == [PlaceID(osmType: "node", osmID: 1), PlaceID(osmType: "node", osmID: 9)])
    }

    // MARK: FTS-hostile text

    @Test("full-text syntax in the text never throws", arguments: [
        "\"", "*", "-", "'", "NEAR(", "AND", "—", "a\"b", "x*", "\"*\"", ":", "^", "OR", "(", ")", "name:col",
        "col AND", "col \"", "* col", "col —", "col -canil",
    ])
    func hostileText(_ text: String) async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            PlaceRow(id: 1, name: "Col Alto", coordinate: Self.point),
            PlaceRow(id: 2, name: "x", coordinate: Self.point),
        ], in: directory)
        let found = try await places.search(text)
        #expect(found.allSatisfy { [1, 2].contains($0.featureID) })
    }

    @Test("text with no words of the data gives nothing")
    func punctuationOnly() async throws {
        let places = try fixturePlaces()
        for text in ["\"", "*", "-", "'", "NEAR(", "AND", "—", "a\"b"] {
            #expect(try await places.search(text).isEmpty, "\(text)")
        }
    }

    @Test("a damaged full-text index throws instead of giving no match")
    func damagedIndexThrows() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "damaged-places.sqlite")
        try FileManager.default.copyItem(at: Fixtures.url("test/test-places.v1.sqlite"), to: url)
        let rootPage: Int
        do {
            let files = try LayerFile.openAll([url], as: .places)
            let statement = try files[0].connection.prepare("SELECT rootpage FROM sqlite_master WHERE name = 'places_fts_data'")
            defer { statement.reset() }
            #expect(try statement.step())
            rootPage = Int(statement.int64(at: 0))
        }
        // Overwrite the b-tree page of the index data, so the file opens but the full-text step cannot read it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64((rootPage - 1) * 4096))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try handle.close()
        do {
            _ = try await Places(files: [url]).search("col")
            Issue.record("a damaged index gave an answer")
        } catch {
            guard case .corruptData(let file, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(file == "damaged-places.sqlite")
        }
    }
}
