import Foundation

/// What the latest release offers for one layer of one pack, as seen by this package version.
public enum LayerAvailability: Sendable, Equatable {
    /// Downloadable: the bytes of every file of the chosen version, that version, and the data dates.
    case available(bytes: Int64, schemaVersion: Int, dataDate: Date, osmTimestamp: Date?)
    /// Every offered version is newer than this package reads; the app needs an update.
    case unreadable(offeredVersions: [Int])
}
