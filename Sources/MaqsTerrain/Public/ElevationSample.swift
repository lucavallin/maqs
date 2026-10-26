/// Why a position has no elevation.
public enum MissingReason: Sendable, Equatable {
    /// No installed region or online source has a tile there, or the tile has no data for it.
    case noData
    /// The online source answered 429 and is cooling down; try again later.
    case rateLimited
    /// The online request failed or timed out; the device may be offline.
    case networkFailure
    /// The call reached its cap on online tile fetches; ask for a smaller area or fewer points.
    case requestCap
}

/// The elevation at one position, or the reason there is none. Failures of online sources are values here, never thrown.
public enum ElevationSample: Sendable, Equatable {
    /// Metres above sea level.
    case elevation(Double)
    /// No elevation, and why.
    case missing(MissingReason)
}
