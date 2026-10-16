import Foundation

/// What the latest data release offers, filtered to this app's layers and compared with what is installed.
public struct Catalog: Sendable, Equatable {
    /// The release tag (`"data-2026-10"`).
    public let release: String
    /// When the release's manifest was created.
    public let createdAt: Date
    /// When the manifest behind this catalog was fetched or last confirmed unchanged.
    public let fetchedAt: Date
    /// The credits the data requires.
    public let attribution: [Attribution]
    /// The region packs the release lists.
    public let regions: [PackSummary]
    /// The base packs that offer at least one configured layer.
    public let basePacks: [PackSummary]

    /// The region or base pack with this id, or `nil` if the release does not list it.
    public func pack(_ id: PackID) -> PackSummary? {
        (regions + basePacks).first { $0.id == id }
    }
}
