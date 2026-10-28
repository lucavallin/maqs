import Foundation
import Network

extension Connectivity {
    /// The device's connectivity from `NWPathMonitor`: the current path first, then every change. The monitor stops
    /// when the stream is no longer iterated.
    static func updates() -> AsyncStream<Connectivity> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied ? .online : .offline)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.lucavallin.maqs.ui.path"))
        }
    }
}
