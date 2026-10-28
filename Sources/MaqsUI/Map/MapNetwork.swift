#if canImport(MapLibre)
import Foundation
import MapLibre

/// MapLibre's network set-up, done once per process before the first map view exists.
///
/// MapLibre builds its session when the first `MLNMapView` is created, even one that never loads a tile, and never
/// reads its configuration again. So the gateway goes first in `protocolClasses` of the configuration MapLibre already
/// has, changed in place and never replaced: appended, or added after the first view, it is never asked.
@MainActor enum MapNetwork {
    private static var prepared = false

    /// Puts the gateway in front of MapLibre's session, sets MapLibre's own `User-Agent` and, when given, the size of
    /// its tile cache. Only the first call does anything.
    static func prepare(userAgent: String, ambientCacheBytes: Int?) {
        guard !prepared else { return }
        prepared = true
        let configuration: URLSessionConfiguration = MLNNetworkConfiguration.sharedManager.sessionConfiguration
        configuration.protocolClasses = [TileGateway.self] + (configuration.protocolClasses ?? [])
        // MapLibre adds this header to each request itself; the gateway sets the same string on what it forwards.
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = userAgent
        configuration.httpAdditionalHeaders = headers
        if let bytes = ambientCacheBytes, bytes < 0 {
            logger.error("map tile cache size \(bytes, privacy: .public) is negative: MapLibre's default is kept")
        } else if let bytes = ambientCacheBytes {
            MLNOfflineStorage.shared.setMaximumAmbientCacheSize(UInt(bytes)) { error in
                if let error {
                    logger.error("map tile cache size not set: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        logger.info("map network prepared: the tile gateway answers first")
    }
}
#endif
