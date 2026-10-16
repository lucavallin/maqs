import Observation

/// The observable face of ``Maqs`` for SwiftUI. Only the package writes it, always on the main actor.
@MainActor @Observable public final class MaqsState {
    /// The latest catalog, or `nil` before the first successful refresh when no manifest is cached.
    public internal(set) var catalog: Catalog?
    /// Every pack the package knows about: installed, queued, in flight, or failed. Absent means not installed.
    public internal(set) var packs: [PackID: PackState] = [:]
    /// The error of the last ``Maqs/refreshCatalog(policy:)`` that failed; `nil` after a success.
    public internal(set) var lastRefreshError: MaqsError?

    init() {}
}
