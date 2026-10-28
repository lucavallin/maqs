#if canImport(MapLibre)
import MapLibre
import SwiftUI
import Testing
import UIKit

@testable import MaqsUI

/// A map shown the way an app shows one: `MaqsMapView` in a hosting controller, in a key window the test creates.
/// Without a window MapLibre loads nothing and asks for no tile. Call ``close()`` when the test ends.
@MainActor final class MapHost {
    let map: MaqsMap
    let coordinator: MaqsMapView.Coordinator
    private let window: UIWindow

    var mapView: MLNMapView { coordinator.mapView }

    /// Shows `map` in light mode, with MapLibre's tile cache emptied first. The map must exist first: its initialiser
    /// prepares MapLibre's network, which must happen before the first view.
    ///
    /// The cache is shared by every test and kept across runs, and what it holds changes what MapLibre asks for and
    /// draws, so each map starts from an empty one.
    static func show(_ map: MaqsMap, size: CGSize = CGSize(width: 390, height: 600)) async throws -> MapHost {
        NetworkTripwire.install()
        let error: (any Error)? = await withCheckedContinuation { continuation in
            MLNOfflineStorage.shared.clearAmbientCache { continuation.resume(returning: $0) }
        }
        if let error { throw error }
        return try MapHost(map: map, size: size)
    }

    private init(map: MaqsMap, size: CGSize) throws {
        self.map = map
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        // Whatever appearance the simulator has: the view picks its style from the colour scheme.
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(rootView: MaqsMapView(map: map))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        coordinator = try #require(map.coordinator, "the hosting controller created no map view")
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Switches the window to light or dark, which makes the view load the style of that scheme.
    func setInterfaceStyle(_ style: UIUserInterfaceStyle) {
        window.overrideUserInterfaceStyle = style
    }

    /// Waits until a style the map assembled has loaded and satisfies `check`.
    func waitForStyle(_ check: @escaping @MainActor (MLNStyle) -> Bool) async throws {
        let coordinator = coordinator
        try await waitUntil {
            coordinator.styleLoads > 0 && coordinator.mapView.style.map(check) == true
        }
    }

    /// Waits until a style the map assembled has loaded and the map has become idle after it: what it shows is drawn.
    /// MapLibre may draw from its own cache before the gateway answers, so this says nothing about the gateway; and
    /// it never becomes idle while tiles keep failing.
    func waitUntilDrawn() async throws {
        let coordinator = coordinator
        try await waitUntil { coordinator.styleLoads > 0 && coordinator.idlesSinceStyleLoad > 0 }
    }
}
#endif
