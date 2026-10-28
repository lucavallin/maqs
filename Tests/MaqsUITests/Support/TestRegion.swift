import CoreLocation
import Foundation
import MaqsTestSupport

@testable import MaqsCore

/// The `test` region of the `data-ci` fixtures, installed through `MaqsCore` from a stub server.
enum TestRegion {
    static let id = PackID.region("test")
    /// The User-Agent of every `Maqs` these tests create. MapLibre keeps the first one it is given for the process.
    static let userAgent = "MaqsUITests/1"
    /// Inside the region's box, `[12.21, 46.08, 12.29, 46.13]`.
    static let center = CLLocationCoordinate2D(latitude: 46.105, longitude: 12.25)

    /// A `Maqs` storing into `directory` whose every request reaches `server`. Nothing is served until the test routes it.
    @MainActor static func maqs(on server: StubServer, layers: Set<Layer>, in directory: TemporaryDirectory) throws -> Maqs {
        var configuration = MaqsConfiguration(layers: layers, userAgent: userAgent)
        configuration.storageDirectory = directory.url
        configuration.urlSessionConfiguration = server.configuration
        return try Maqs(configuration: configuration)
    }

    /// Serves the `data-ci` release on `server`, then installs the `test` region with `layers` into `directory`.
    @MainActor static func install(on server: StubServer, layers: Set<Layer>, in directory: TemporaryDirectory) async throws -> Maqs {
        try Fixtures.serveRelease(on: server)
        let maqs = try maqs(on: server, layers: layers, in: directory)
        _ = try await maqs.refreshCatalog()
        try await maqs.install(id)
        return maqs
    }

    /// Every URL of the release now fails as not connected; any other URL already gets a 404.
    static func failEveryRequest(on server: StubServer) throws {
        let failing: StubServer.Handler = { _ in StubResponse(transportError: .notConnectedToInternet) }
        server.route(Fixtures.manifestURL, failing)
        for (url, _) in try Fixtures.entryURLs(in: Fixtures.manifestData()) {
            server.route(url, failing)
        }
    }
}
