/// Whether and from where the map shows the user's location. The map never asks for location permission; the app
/// asks before it shows the location.
public enum UserLocationMode: Sendable, Equatable {
    /// No location is shown.
    case hidden
    /// The map reads the location from the system itself.
    case system
    /// The app passes each location to the map, for example the fixes it records.
    case provided
}
