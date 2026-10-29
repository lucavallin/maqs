#if canImport(MapLibre)
import CoreLocation
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
        let dark = colorScheme == .dark
        Representable(map: map, style: map.styles?.json(dark: dark), dark: dark)
    }
}

extension MaqsMapView {
    /// Hosts the MapLibre view; the coordinator owns it.
    struct Representable: UIViewRepresentable {
        let map: MaqsMap
        /// The style for the current scheme; `nil` until the map has read its packs.
        let style: String?
        /// Whether that style is the dark one.
        let dark: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator(map: map)
        }

        func makeUIView(context: Context) -> MLNMapView {
            context.coordinator.setLayoutDirection(context.environment.layoutDirection)
            context.coordinator.apply(style, dark: dark)
            return context.coordinator.mapView
        }

        func updateUIView(_ mapView: MLNMapView, context: Context) {
            context.coordinator.setLayoutDirection(context.environment.layoutDirection)
            context.coordinator.apply(style, dark: dark)
        }

        static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
            coordinator.detach()
        }
    }

    /// Owns the `MLNMapView`, hands it the styles `MaqsMap` assembles and reports back what MapLibre does. Every
    /// MapLibre call happens here, on the main actor.
    @MainActor @Observable final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate,
        UIGestureRecognizerDelegate {
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

        /// The side of the square around a tap that counts as touched, in points.
        static let tapSide: CGFloat = 44

        let mapView: MLNMapView
        /// The map's own single tap. It waits for MapLibre's double tap and tap-and-drag zoom to fail, as MapLibre's own
        /// single tap does, so neither gesture is reported as a tap.
        let tapRecognizer: UITapGestureRecognizer
        @ObservationIgnored private weak var map: MaqsMap?
        /// The style last handed to MapLibre, the last one that loaded, and one MapLibre failed to load, which is not
        /// handed over again.
        @ObservationIgnored private(set) var appliedStyle: String?
        private(set) var loadedStyle: String?
        @ObservationIgnored private var failedStyle: String?
        /// Whether the applied and the loaded style are the dark ones. The images of the content follow the scheme of
        /// the style that loaded.
        @ObservationIgnored private var appliedDark = false
        @ObservationIgnored private var loadedDark = false
        /// The marker images added to the loaded style. A style load drops every image added at run time.
        @ObservationIgnored private var markerImages: Set<String> = []
        /// How often an assembled style loaded, and how often the map became idle since the last load, for whoever
        /// waits on the map.
        private(set) var styleLoads = 0
        private(set) var idlesSinceStyleLoad = 0
        /// What MapLibre last said when it finished rendering the map. It says `true` even when no tile could be parsed.
        private(set) var renderedFully = false
        /// The location manager of ``UserLocationMode/provided``, installed only in that mode.
        let providedLocationManager = ProvidedLocationManager()
        /// MapLibre's own location manager, kept while the provided one is installed so ``UserLocationMode/system``
        /// gets it back.
        @ObservationIgnored private var systemLocationManager: (any MLNLocationManager)?
        /// SwiftUI's layout direction, which says which side the leading and trailing insets are on.
        @ObservationIgnored private var layoutDirection = LayoutDirection.leftToRight

        init(map: MaqsMap) {
            mapView = OrnamentlessMapView(frame: .zero, styleJSON: Self.emptyStyle)
            tapRecognizer = UITapGestureRecognizer()
            self.map = map
            super.init()
            mapView.delegate = self
            tapRecognizer.delegate = self
            tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
            for recognizer in mapView.gestureRecognizers ?? [] {
                if let doubleTap = recognizer as? UITapGestureRecognizer, doubleTap.numberOfTapsRequired == 2 {
                    tapRecognizer.require(toFail: doubleTap)
                }
                if let quickZoom = recognizer as? UILongPressGestureRecognizer, quickZoom.numberOfTapsRequired == 1 {
                    tapRecognizer.require(toFail: quickZoom)
                }
            }
            mapView.addGestureRecognizer(tapRecognizer)
            mapView.showsCompassView = false
            mapView.showsLogoView = false
            mapView.showsAttributionButton = false
            mapView.showsScale = false
            // Hidden from accessibility as well, and left out of the view's accessibility children
            // (OrnamentlessMapView): VoiceOver must not open MapLibre's own credits. The location stays.
            for ornament in [mapView.compassView, mapView.attributionButton, mapView.logoView] as [UIView] {
                ornament.isAccessibilityElement = false
                ornament.accessibilityElementsHidden = true
            }
            // The app asks for location permission; MapLibre asking itself raises an exception without the usage text.
            mapView.shouldRequestAuthorizationToUseLocationServices = false
            // The insets are the app's. Left unset, MapLibre puts the safe area over them on every layout whenever a
            // view controller holds the view directly, reading that controller's deprecated scroll-view setting.
            mapView.automaticallyAdjustsContentInset = false
            mapView.tintColor = Self.locationColor
            map.attach(self)
            showContentInsets()
            showUserLocation()
            follow(map.followMode)
        }

        /// Loads `style`, the dark one when `dark` says so, unless it is already loaded or MapLibre has rejected it.
        func apply(_ style: String?, dark: Bool) {
            guard let style, style != appliedStyle, style != failedStyle else { return }
            appliedStyle = style
            appliedDark = dark
            failedStyle = nil
            mapView.styleJSON = style
        }

        func detach() {
            map?.detach(self)
        }

        // MARK: Camera and location

        func setLayoutDirection(_ direction: LayoutDirection) {
            guard direction != layoutDirection else { return }
            layoutDirection = direction
            showContentInsets()
        }

        /// Sets the map's content insets, leading and trailing as SwiftUI's layout direction reads them. A negative
        /// inset or one that is not finite counts as none.
        func showContentInsets() {
            guard let insets = map?.contentInsets else { return }
            let rightToLeft = layoutDirection == .rightToLeft
            func usable(_ value: CGFloat) -> CGFloat { value.isFinite ? max(value, 0) : 0 }
            let edges = UIEdgeInsets(
                top: usable(insets.top), left: usable(rightToLeft ? insets.trailing : insets.leading),
                bottom: usable(insets.bottom), right: usable(rightToLeft ? insets.leading : insets.trailing))
            mapView.setContentInset(edges, animated: mapView.window != nil, completionHandler: nil)
        }

        /// Shows or hides the user's location, with the manager the map's mode needs.
        func showUserLocation() {
            guard let map else { return }
            switch map.userLocation {
            case .hidden:
                mapView.showsUserLocation = false
            case .system where mapView.locationManager === providedLocationManager:
                install(systemLocationManager)
            case .provided where mapView.locationManager !== providedLocationManager:
                systemLocationManager = mapView.locationManager
                install(providedLocationManager)
            case .system, .provided:
                mapView.showsUserLocation = true
            }
        }

        /// Puts `manager` in, or MapLibre's default for `nil`, and shows the location. MapLibre starts a manager only
        /// when the location turns on, so the location goes off for the swap, which stops following; it resumes after.
        private func install(_ manager: (any MLNLocationManager)?) {
            let mode = map?.followMode ?? .none
            mapView.showsUserLocation = false
            mapView.locationManager = manager
            mapView.showsUserLocation = true
            follow(mode)
        }

        /// MapLibre reports the mode back through the delegate, which updates the map's ``MaqsMap/followMode``.
        func follow(_ mode: FollowMode) {
            mapView.setUserTrackingMode(MLNUserTrackingMode(mode), animated: true, completionHandler: nil)
        }

        /// Whether a camera change may animate. While MapLibre follows the location, each location or heading update
        /// cancels a running animation and moves on without its pitch, and without its bearing unless it follows the
        /// course, so a change made then would stop partway: it is made at once instead.
        private var cameraMayAnimate: Bool {
            mapView.userTrackingMode == .none
        }

        func resetNorth() {
            if cameraMayAnimate {
                mapView.resetNorth()
            } else {
                mapView.setDirection(0, animated: false)
            }
        }

        /// Tilts the camera at the same distance from the centre, so the zoom stays.
        func setPitch(_ degrees: Double) {
            let camera = mapView.camera
            mapView.setCamera(MLNMapCamera(lookingAtCenter: camera.centerCoordinate, acrossDistance: camera.viewingDistance,
                                           pitch: degrees, heading: camera.heading), animated: cameraMayAnimate)
        }

        func show(_ coordinate: CLLocationCoordinate2D, zoom: Double?) {
            mapView.setCenter(coordinate, zoomLevel: zoom ?? mapView.zoomLevel, animated: true)
        }

        /// Whether the view has a size to fit a box to. MapLibre fits one to the size at the call, and below 64 points it
        /// counts 64, so a box fitted before the first layout comes out far too small.
        var canFitBounds: Bool {
            !mapView.bounds.isEmpty
        }

        /// MapLibre adds the content inset to the edge padding, so the box fits inside the app's insets.
        func show(_ bounds: BoundingBox, animated: Bool) {
            let box = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon),
                                          ne: CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon))
            mapView.setVisibleCoordinateBounds(box, edgePadding: .zero, animated: animated, completionHandler: nil)
        }

        func provide(_ location: CLLocation) {
            providedLocationManager.provide(location)
        }

        // MARK: Content

        /// Sets the `maqs-lines` data from the map's lines. Nothing happens before an assembled style has loaded: the
        /// load sets it.
        func showLines() {
            guard let style = mapView.style else { return }
            showLines(on: style)
        }

        /// Adds the images of the map's markers that the style lacks, then sets the `maqs-markers` data.
        func showMarkers() {
            guard let style = mapView.style else { return }
            showMarkers(on: style)
        }

        /// Filters each region's selected-trail layer to the selected feature, or to nothing.
        func showSelectedOverlayFeature() {
            guard let style = mapView.style else { return }
            showSelectedOverlayFeature(on: style)
        }

        private func showLines(on style: MLNStyle) {
            guard let map, let source = style.source(withIdentifier: "maqs-lines") as? MLNShapeSource else { return }
            setShape(LineFeatures.geoJSON(map.lines, activeID: map.activeLineID), of: source)
        }

        private func showMarkers(on style: MLNStyle) {
            guard let map, let source = style.source(withIdentifier: "maqs-markers") as? MLNShapeSource else { return }
            let dark = loadedDark
            let accent = map.accentColor(dark: dark)
            let keys = map.markers.map { marker in
                let selected = marker.id == map.selectedMarkerID
                let name = MarkerImages.name(
                    for: marker.content, hidden: marker.isHidden, selected: selected, accent: accent, dark: dark)
                if markerImages.insert(name).inserted {
                    let image = MarkerImages.image(
                        for: marker.content, hidden: marker.isHidden, selected: selected, accent: accent, dark: dark)
                    style.setImage(image, forName: name)
                }
                return MarkerKey(id: marker.id, coordinate: marker.coordinate, imageName: name, label: marker.label,
                                 isHidden: marker.isHidden)
            }
            setShape(MarkerFeatures.geoJSON(keys, selectedID: map.selectedMarkerID), of: source)
        }

        /// The overlays' trails are `maqs-trails-<region>`, each with a `-selected` layer the assembled style filters to
        /// no feature (`-1`); the feature's `id` is a property of the tiles, the row of the region's SQLite file.
        private func showSelectedOverlayFeature(on style: MLNStyle) {
            let selected = map?.selectedOverlayFeature
            for source in style.sources where source.identifier.hasPrefix(TapTarget.trailsPrefix) {
                guard let layer = style.layer(withIdentifier: source.identifier + "-selected") as? MLNVectorStyleLayer
                else { continue }
                let region = String(source.identifier.dropFirst(TapTarget.trailsPrefix.count))
                let featureID = selected?.region == region ? selected?.featureID ?? -1 : -1
                layer.predicate = NSPredicate(mglJSONObject: ["==", ["get", "id"], featureID])
            }
        }

        /// The place-kind pictograms and the trail plate of the loaded style's scheme, which its overlay layers name.
        private func addOverlayImages(to style: MLNStyle, dark: Bool) {
            for kind in MarkerImages.placeKinds + ["other"] {
                style.setImage(MarkerImages.placeKindImage(kind, dark: dark), forName: MarkerImages.placeKindName(kind, dark: dark))
            }
            style.setImage(MarkerImages.plateImage(), forName: MarkerImages.plateName(dark: dark))
        }

        private func setShape(_ geoJSON: Data, of source: MLNShapeSource) {
            do {
                source.shape = try MLNShape(data: geoJSON, encoding: String.Encoding.utf8.rawValue)
            } catch {
                // The message may quote the data, which holds the app's coordinates.
                logger.error("map \(source.identifier, privacy: .public) not updated: \(error.localizedDescription, privacy: .private)")
            }
        }

        // MARK: Taps

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            tap(at: recognizer.location(in: mapView))
        }

        /// Hands the app a tap at `point` of the map view with what lies in the ``tapSide`` square around it.
        func tap(at point: CGPoint) {
            guard let onTap = map?.onTap else { return }
            onTap(MapTap(coordinate: mapView.convert(point, toCoordinateFrom: mapView), hits: hits(at: point)))
        }

        /// Asks MapLibre once per run of `maqs-` layers with one source, from the top of the style down, so the hits
        /// are topmost first and each knows its region. MapLibre returns a feature once per tile it lies in, so a hit
        /// is kept once.
        private func hits(at point: CGPoint) -> [MapHit] {
            guard let style = mapView.style else { return [] }
            let rect = CGRect(x: point.x - Self.tapSide / 2, y: point.y - Self.tapSide / 2,
                              width: Self.tapSide, height: Self.tapSide)
            var runs: [(target: TapTarget, layers: Set<String>)] = []
            for layer in style.layers.reversed() {
                guard let layer = layer as? MLNVectorStyleLayer, layer.identifier.hasPrefix(StyleAssembler.reservedPrefix),
                      let target = layer.sourceIdentifier.flatMap(TapTarget.init(source:)) else { continue }
                if runs.last?.target == target {
                    runs[runs.count - 1].layers.insert(layer.identifier)
                } else {
                    runs.append((target, [layer.identifier]))
                }
            }
            var hits: [MapHit] = []
            var seen: Set<MapHit> = []
            for run in runs {
                for feature in mapView.visibleFeatures(in: rect, styleLayerIdentifiers: run.layers) {
                    guard let hit = run.target.hit(feature), seen.insert(hit).inserted else { continue }
                    hits.append(hit)
                }
            }
            return hits
        }

        /// MapLibre's own single tap, on the map view itself, begins only over an annotation, here the user's location,
        /// or while one is selected, and selects or deselects it. Alone, it and the map's tap compete, and a tap on the
        /// location, or the next tap after it, may never reach `onTap`. So both recognize: MapLibre's selection shows
        /// nothing, as the map gives no annotation a callout, and the app gets the tap with what lies under it. Taps
        /// an app adds to other views are left to UIKit.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === tapRecognizer, let tap = other as? UITapGestureRecognizer,
                  tap.view === mapView else { return false }
            return tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1
        }

        // MARK: MLNMapViewDelegate

        /// A load drops every image and every GeoJSON payload added at run time, whoever started it (a new style, the
        /// scheme, or MapLibre itself), so the content comes back here.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            guard let appliedStyle else { return }
            loadedStyle = appliedStyle
            loadedDark = appliedDark
            markerImages = []
            addOverlayImages(to: style, dark: loadedDark)
            showLines(on: style)
            showMarkers(on: style)
            showSelectedOverlayFeature(on: style)
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
            appliedDark = loadedDark
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

        /// The first layout with a size changes the region too: a box the map was asked to show before is fitted then,
        /// at once.
        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if canFitBounds, let pending = map?.takePendingBounds() {
                show(pending, animated: false)
            }
            let bounds = mapView.visibleCoordinateBounds
            map?.cameraDidSettle(MapCamera(
                center: mapView.centerCoordinate, zoom: mapView.zoomLevel, heading: mapView.direction,
                pitch: mapView.camera.pitch,
                visibleBounds: BoundingBox(minLon: bounds.sw.longitude, minLat: bounds.sw.latitude,
                                           maxLon: bounds.ne.longitude, maxLat: bounds.ne.latitude)))
        }

        /// Every change of MapLibre's tracking comes here: the map's own, a pan (none), a rotation or north-up
        /// (heading and course become follow), a hidden or denied location (none).
        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            map?.followModeDidChange(FollowMode(mode))
        }

        /// MapLibre turns the location off when the system denies it and does not turn it on again when the user
        /// allows it later; with ``UserLocationMode/system`` the map does.
        func mapView(_ mapView: MLNMapView, didChangeLocationManagerAuthorization manager: any MLNLocationManager) {
            guard map?.userLocation == .system, !mapView.showsUserLocation,
                  [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return }
            mapView.showsUserLocation = true
        }
    }

    /// What the features of a `maqs-` layer are, told by the layer's source: the app's markers or lines, or one
    /// region's trails or places overlay (`maqs-trails-<region>`, `maqs-places-<region>`).
    private enum TapTarget: Equatable {
        case marker
        case line
        case trail(region: String)
        case place(region: String)

        static let trailsPrefix = "maqs-trails-"
        static let placesPrefix = "maqs-places-"

        init?(source: String) {
            if source == "maqs-markers" {
                self = .marker
            } else if source == "maqs-lines" {
                self = .line
            } else if source.hasPrefix(Self.trailsPrefix) {
                self = .trail(region: String(source.dropFirst(Self.trailsPrefix.count)))
            } else if source.hasPrefix(Self.placesPrefix) {
                self = .place(region: String(source.dropFirst(Self.placesPrefix.count)))
            } else {
                return nil
            }
        }

        /// The hit for one of these features; `nil` for a feature without the id this kind needs.
        func hit(_ feature: any MLNFeature) -> MapHit? {
            switch self {
            case .marker: (feature.attribute(forKey: "maqs_id") as? String).map(MapHit.marker)
            case .line: (feature.attribute(forKey: "maqs_id") as? String).map(MapHit.line)
            case .trail(let region): Self.featureID(feature).map { .trail(OverlayFeature(region: region, featureID: $0)) }
            case .place(let region): Self.featureID(feature).map { .place(OverlayFeature(region: region, featureID: $0)) }
            }
        }

        /// An overlay feature's `id` property, the row of its region's SQLite file. The tiles carry it as a property,
        /// not as the vector tile feature id.
        private static func featureID(_ feature: any MLNFeature) -> Int64? {
            (feature.attribute(forKey: "id") as? NSNumber)?.int64Value
        }
    }
}

private extension MLNUserTrackingMode {
    init(_ mode: FollowMode) {
        switch mode {
        case .none: self = MLNUserTrackingMode.none
        case .position: self = .follow
        case .heading: self = .followWithHeading
        case .course: self = .followWithCourse
        }
    }
}

private extension FollowMode {
    /// A mode MapLibre adds later counts as none.
    init(_ mode: MLNUserTrackingMode) {
        switch mode {
        case .follow: self = .position
        case .followWithHeading: self = .heading
        case .followWithCourse: self = .course
        default: self = FollowMode.none
        }
    }
}
#endif
