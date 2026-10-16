import Foundation

/// A credit the data requires, from the manifest's `attribution` list.
public struct Attribution: Sendable, Hashable, Identifiable {
    /// The text to show, verbatim (`"© OpenStreetMap contributors"`).
    public let text: String
    /// The licence the credit names.
    public let licence: String
    /// Where the credit links to.
    public let url: URL
    /// The layers this credit applies to; unknown layer names were dropped.
    public let layers: [Layer]
    /// The credit text, which is unique within a manifest.
    public var id: String { text }
}
