#if canImport(MapLibre)
import MapLibre
import MaqsCore
import SwiftUI
import UIKit

/// Shows a ``MaqsMap``. The view follows the colour scheme of its environment: the light style in light mode, the dark
/// one in dark mode. It draws no controls, no compass, logo or scale; the app places its own chrome, and
/// ``MaqsMap`` reports what it needs.
public struct MaqsMapView: View {
    private let map: MaqsMap
    @Environment(\.colorScheme) private var colorScheme

    /// Creates a view of `map`.
    public init(map: MaqsMap) {
        self.map = map
    }

    public var body: some View {
        Representable(map: map, style: map.styles?.json(dark: colorScheme == .dark))
    }
}

extension MaqsMapView {
    /// Hosts the MapLibre view; the coordinator owns it.
    struct Representable: UIViewRepresentable {
        let map: MaqsMap
        /// The style for the current scheme; `nil` until the map has read its packs.
        let style: String?

        func makeCoordinator() -> Coordinator {
            Coordinator(map: map)
        }

        func makeUIView(context: Context) -> MLNMapView {
            context.coordinator.apply(style)
            return context.coordinator.mapView
        }

        func updateUIView(_ mapView: MLNMapView, context: Context) {
            context.coordinator.apply(style)
        }

        static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
            coordinator.detach()
        }
    }

    /// Owns the `MLNMapView`, hands it the styles `MaqsMap` assembles and reports back what MapLibre does. Every
    /// MapLibre call happens here, on the main actor.
    @MainActor @Observable final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        /// The style the view starts with. A real style comes once the delegate is set, because MapLibre loads a style
        /// synchronously inside its initialiser and inside the `styleJSON` setter, and a delegate set later never hears
        /// of the first load. A view created without a style would fetch MapLibre's demo style from its own host.
        static let emptyStyle = #"{"version":8,"sources":{},"layers":[]}"#
        /// The user's location, `#1C6CF7` light and `#61D0FF` dark; the puck takes the view's tint.
        static let locationColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x61 / 255, green: 0xD0 / 255, blue: 0xFF / 255, alpha: 1)
                : UIColor(red: 0x1C / 255, green: 0x6C / 255, blue: 0xF7 / 255, alpha: 1)
        }

        let mapView: MLNMapView
        @ObservationIgnored private weak var map: MaqsMap?
        /// The style last handed to MapLibre, the last one that loaded, and one MapLibre failed to load, which is not
        /// handed over again.
        @ObservationIgnored private(set) var appliedStyle: String?
        private(set) var loadedStyle: String?
        @ObservationIgnored private var failedStyle: String?
        /// How often an assembled style loaded, and how often the map became idle since the last load, for whoever
        /// waits on the map.
        private(set) var styleLoads = 0
        private(set) var idlesSinceStyleLoad = 0
        /// What MapLibre last said when it finished rendering the map. It says `true` even when no tile could be parsed.
        private(set) var renderedFully = false

        init(map: MaqsMap) {
            mapView = MLNMapView(frame: .zero, styleJSON: Self.emptyStyle)
            self.map = map
            super.init()
            mapView.delegate = self
            mapView.showsCompassView = false
            mapView.showsLogoView = false
            mapView.showsAttributionButton = false
            mapView.showsScale = false
            // The app asks for location permission; MapLibre asking itself raises an exception without the usage text.
            mapView.shouldRequestAuthorizationToUseLocationServices = false
            mapView.tintColor = Self.locationColor
            map.attach(self)
        }

        /// Loads `style` unless it is already loaded or MapLibre has rejected it.
        func apply(_ style: String?) {
            guard let style, style != appliedStyle, style != failedStyle else { return }
            appliedStyle = style
            failedStyle = nil
            mapView.styleJSON = style
        }

        func detach() {
            map?.detach(self)
        }

        // MARK: MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            guard let appliedStyle else { return }
            loadedStyle = appliedStyle
            styleLoads += 1
            idlesSinceStyleLoad = 0
            map?.styleDidLoad()
        }

        /// MapLibre keeps drawing the previous style after a style it cannot parse, but drops its `MLNStyle` object,
        /// so the previous JSON is loaded again to bring it back; not from inside this callback, which can run inside
        /// the `styleJSON` setter.
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: any Error) {
            map?.styleDidFail(error)
            guard let loadedStyle, appliedStyle != loadedStyle else { return }
            failedStyle = appliedStyle
            appliedStyle = loadedStyle
            Task { @MainActor [weak self] in
                guard let self, self.appliedStyle == loadedStyle else { return }
                self.mapView.styleJSON = loadedStyle
            }
        }

        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
            renderedFully = fullyRendered
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            idlesSinceStyleLoad += 1
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let bounds = mapView.visibleCoordinateBounds
            map?.cameraDidSettle(MapCamera(
                center: mapView.centerCoordinate, zoom: mapView.zoomLevel, heading: mapView.direction,
                pitch: mapView.camera.pitch,
                visibleBounds: BoundingBox(minLon: bounds.sw.longitude, minLat: bounds.sw.latitude,
                                           maxLon: bounds.ne.longitude, maxLat: bounds.ne.latitude)))
        }
    }
}
#endif
