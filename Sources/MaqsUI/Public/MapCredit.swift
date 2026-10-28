import Foundation

/// One credit the map must show: the text, and where it links to when the source has a page for it.
public struct MapCredit: Hashable, Sendable, Identifiable {
    /// The credit text, verbatim (`"© OpenStreetMap contributors"`).
    public let text: String
    /// The page the credit links to, or `nil` when only the text is known.
    public let url: URL?
    /// The credit text, which is unique within a list of credits.
    public var id: String { text }

    /// Creates a credit.
    public init(text: String, url: URL?) {
        self.text = text
        self.url = url
    }
}
