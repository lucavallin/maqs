import CoreLocation
import Observation

/// Asks for when-in-use location permission and reports the answer. The map never asks; the app does, before it
/// shows the location.
@MainActor @Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager: CLLocationManager
    /// The permission as the system last reported it.
    private(set) var status: CLAuthorizationStatus
    /// Runs once with the answer to the demo's request: `true` when the user allowed it.
    @ObservationIgnored private var onAnswer: ((Bool) -> Void)?

    /// Starts listening for permission changes; `manager` must be made on the main thread, where it calls back.
    init(manager: CLLocationManager) {
        self.manager = manager
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Shows the system's when-in-use prompt and runs `onAnswer` once the user has answered it.
    func request(onAnswer: @escaping (_ granted: Bool) -> Void) {
        self.onAnswer = onAnswer
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // Core Location calls back on the thread that made the manager: the main thread.
        MainActor.assumeIsolated { self.update(status) }
    }

    private func update(_ status: CLAuthorizationStatus) {
        self.status = status
        // Any answer ends the request, so a later change in Settings does not act on it.
        guard status != .notDetermined, let onAnswer else { return }
        self.onAnswer = nil
        onAnswer(status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
