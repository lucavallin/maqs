import Foundation

/// Everything an app tells ``Terrain`` once, when it creates it.
public struct TerrainConfiguration: Sendable {
    /// Installed terrarium PMTiles archives. Where several cover a position, the one with the highest zoom wins.
    public var archives: [URL]
    /// The online elevation source used where no archive has a tile, or `nil` for offline-only.
    public var online: OnlineTerrainSource?
    /// An app-identifying `User-Agent` prefix such as `"MyApp/1.2 (iOS)"`. The package appends its own token.
    /// Free tile providers block generic agents, so ``Terrain/init(configuration:)`` throws
    /// ``TerrainError/invalidConfiguration(_:)`` when ``online`` is set and this is empty or only whitespace.
    public var userAgent: String
    /// The most bytes of decoded tiles kept in memory. Defaults to 64 MiB.
    ///
    /// A call reads its tiles in batches of about this size and samples each batch before reading the next, so while it
    /// runs it holds the cache and one batch: about twice this value at most.
    public var memoryCacheBytes: Int = 64 << 20
    /// The size of the on-disk HTTP cache for online tiles. Defaults to 64 MiB.
    ///
    /// URLSession stores a response on disk only when it is at most about 5 % of the disk capacity, so the default keeps
    /// tiles of up to about 3 MB. Keep this value well above 20 times the largest tile the source serves.
    public var diskCacheBytes: Int = 64 << 20

    /// Test seam: a stub `URLProtocol` is injected through `protocolClasses`. The configuration is copied, never mutated.
    var urlSessionConfiguration: URLSessionConfiguration = .default
    /// Test seam: where the online tile cache lives. `nil` keeps the session configuration's own cache.
    var cacheDirectory: URL? = URL.cachesDirectory.appending(path: "Maqs/terrain-tiles", directoryHint: .isDirectory)
    /// Test seam: the clock used for the 429 cool-down.
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    /// Creates a configuration with the values most apps set; every other field has a default.
    public init(archives: [URL], online: OnlineTerrainSource? = nil, userAgent: String = "") {
        self.archives = archives
        self.online = online
        self.userAgent = userAgent
    }

    /// The full `User-Agent` header value: the app's string followed by the package token.
    var fullUserAgent: String { "\(userAgent) Maqs/\(TerrainVersion.string)" }
}
