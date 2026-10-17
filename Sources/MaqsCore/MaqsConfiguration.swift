import Foundation

/// Everything an app tells `MaqsCore` once, when it creates its ``Maqs`` instance.
public struct MaqsConfiguration: Sendable {
    /// The layers this app needs. Only these are shown in the catalog and downloaded.
    public var layers: Set<Layer>
    /// An app-identifying `User-Agent` prefix such as `"MyApp/1.2 (iOS)"`. The package appends its own token.
    /// Free tile providers block generic agents; this is required.
    public var userAgent: String
    /// `false` turns every online tile and DEM request off (ADR 0008): ``Maqs/onlineSources`` is then `nil`.
    /// `manifest.json` and `sources.json` fetches stay allowed; they carry no position.
    public var onlineTiles: Bool = true
    /// A background `URLSession` identifier. Set it on iOS so downloads survive suspension;
    /// `nil` uses a foreground session (macOS, tests).
    public var backgroundSessionIdentifier: String?
    /// Where the latest manifest is read from. Only this file is read through `latest`.
    public var manifestURL = URL(string: "https://github.com/lucavallin/maqs/releases/latest/download/manifest.json")!
    /// Where the online providers file is read from.
    public var sourcesURL = URL(string: "https://raw.githubusercontent.com/lucavallin/maqs/main/config/sources.json")!
    /// The storage root. `nil` means `Application Support/Maqs` in the app's container.
    public var storageDirectory: URL?
    /// How old a cached manifest may be before ``RefreshPolicy/ifStale`` fetches again.
    public var catalogMaxAge: Duration = .seconds(86_400)

    /// Test seam: a stub `URLProtocol` is injected through `protocolClasses`. Ignored for background sessions.
    var urlSessionConfiguration: URLSessionConfiguration = .default
    /// Test seam: the clock used for staleness.
    var now: @Sendable () -> Date = { Date() }

    /// Creates a configuration with the two required values; every other field has a default.
    public init(layers: Set<Layer>, userAgent: String) {
        self.layers = layers
        self.userAgent = userAgent
    }

    /// The full `User-Agent` header value: the app's string followed by the package token.
    var fullUserAgent: String { "\(userAgent) \(MaqsVersion.userAgentToken)" }
}
