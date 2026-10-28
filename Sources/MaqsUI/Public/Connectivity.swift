/// Whether the device can reach the network, as the system reports it.
public enum Connectivity: Sendable, Equatable {
    /// A network path is available.
    case online
    /// No network path is available: the map draws installed regions and what it has cached, and asks for nothing.
    case offline
}
