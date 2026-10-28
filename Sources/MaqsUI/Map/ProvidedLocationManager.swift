#if canImport(MapLibre)
import CoreLocation
import MapLibre

/// The location manager of a map whose app passes the locations itself (``UserLocationMode/provided``): MapLibre gets
/// what ``provide(_:)`` is given and nothing else. It never asks for permission and reports when-in-use authorisation,
/// because the app owns the locations it passes; starting and stopping only record what MapLibre asked for.
@MainActor final class ProvidedLocationManager: NSObject, @preconcurrency MLNLocationManager {
    /// The map view, which MapLibre sets when it installs this manager and clears when it replaces it.
    weak var delegate: (any MLNLocationManagerDelegate)?
    var headingOrientation: CLDeviceOrientation = .portrait
    private(set) var isUpdatingLocation = false
    private(set) var isUpdatingHeading = false

    var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }

    func requestAlwaysAuthorization() {}

    func requestWhenInUseAuthorization() {}

    func startUpdatingLocation() { isUpdatingLocation = true }

    func stopUpdatingLocation() { isUpdatingLocation = false }

    func startUpdatingHeading() { isUpdatingHeading = true }

    func stopUpdatingHeading() { isUpdatingHeading = false }

    func dismissHeadingCalibrationDisplay() {}

    /// Hands `location` to the map view, which moves the user's location to it.
    func provide(_ location: CLLocation) {
        delegate?.locationManager(self, didUpdate: [location])
    }
}
#endif
