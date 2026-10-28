#if canImport(MapLibre)
import Foundation
import MapLibre
import Synchronization

@testable import MaqsUI

/// Stands right after the gateway in MapLibre's own session: every request the gateway does not take (anything that is
/// not a tile of the current templates) lands here instead of on the network, is recorded and fails as not connected.
/// A test that expects no network then checks that ``requests`` is empty, glyphs, sprites and overlays included.
final class NetworkTripwire: URLProtocol {
    private static let seen = Mutex<[URL]>([])
    private static let installed = Mutex(false)

    /// Puts the tripwire behind the gateway, once per process. Call it after `MapNetwork.prepare` (which `MaqsMap.init`
    /// runs) and before the first map view: MapLibre reads its session configuration when the first view is created.
    static func install() {
        installed.withLock { installed in
            guard !installed else { return }
            installed = true
            let configuration: URLSessionConfiguration = MLNNetworkConfiguration.sharedManager.sessionConfiguration
            var classes = configuration.protocolClasses ?? []
            let gateway = classes.firstIndex { ObjectIdentifier($0) == ObjectIdentifier(TileGateway.self) }
            classes.insert(NetworkTripwire.self, at: gateway.map { $0 + 1 } ?? 0)
            configuration.protocolClasses = classes
        }
    }

    /// The URLs that reached the tripwire since the last ``reset()``.
    static var requests: [URL] { seen.withLock { $0 } }

    static func reset() { seen.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.seen.withLock { $0.append(url) } }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#endif
