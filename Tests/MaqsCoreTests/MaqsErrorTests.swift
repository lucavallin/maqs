import Testing
@testable import MaqsCore

@Suite struct MaqsErrorTests {
    @Test("a message names a pack by its raw id, a base pack with the word base")
    func packNames() {
        #expect(MaqsError.download(.notInCatalog(.region("veneto"))).errorDescription
            == "veneto is not in the current catalog. Refresh and try again.")
        #expect(MaqsError.storage(.corruptRecord(.base("triveneto"))).errorDescription
            == "The record of base triveneto is unreadable. Reinstall the pack.")
        #expect(MaqsError.storage(.invalidPackID(.region("Veneto"))).errorDescription
            == "\"Veneto\" is not a valid pack id. Use an id from the catalog.")
    }

    @Test("every message says what to do")
    func actions() {
        let path = "regions.[0].layers.trails.[0].url"
        #expect(MaqsError.manifest(.insecureURL(path)).errorDescription
            == "The map data index points at a non-HTTPS address at \(path) and was rejected. Try again later.")
        #expect(MaqsError.manifest(.foreignHost(path)).errorDescription
            == "The map data index points outside its own host at \(path) and was rejected. Try again later.")
        #expect(MaqsError.download(.cancelled).errorDescription == "The download was cancelled. Start it again to continue.")
        #expect(MaqsError.sources(.unsupportedVersion(2)).errorDescription
            == "The online sources file (version 2) needs a newer app. Update the app.")
        #expect(MaqsError.sources(.invalid("layers.basemap: must not be empty")).errorDescription
            == "The online sources file could not be read (layers.basemap: must not be empty). The last good copy stays in use; try again later.")
        #expect(MaqsError.sources(.network(statusCode: 500)).errorDescription
            == "The online sources file could not be fetched (HTTP 500). The last good copy stays in use; check the connection and try again.")
        #expect(MaqsError.invalidConfiguration("userAgent: must not be blank").errorDescription
            == "The package configuration was rejected (userAgent: must not be blank). Set an app-identifying User-Agent such as \"MyApp/1.2 (iOS)\".")
    }
}
