/// The package version, as sent in the `User-Agent` of every request this package makes.
enum MaqsVersion {
    /// Bump with each tagged release.
    static let string = "0.1.0"
    static var userAgentToken: String { "Maqs/\(string)" }
}
