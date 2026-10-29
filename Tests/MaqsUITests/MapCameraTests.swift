#if canImport(MapLibre)
import CoreLocation
import Foundation
import MapLibre
import MaqsTestSupport
import SwiftUI
import Testing
import UIKit

@testable import MaqsCore
@testable import MaqsUI

extension SharedGatewaySuite {
    /// The camera actions, the follow modes and the user's location on real MapLibre views, and connectivity reaching
    /// the gateway. Nothing is installed; tiles go to a stub server that answers 404. The locations are points of the
    /// `test` region, not anyone's position.
    @MainActor @Suite(.timeLimit(.minutes(1))) struct MapCameraTests {
        private let server = StubServer()
        private let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
            GatewayState.shared.resetForTesting()
            NetworkTripwire.reset()
        }

        private func seams(_ connectivity: @escaping () -> AsyncStream<Connectivity> = { AsyncStream { $0.yield(.online) } })
            -> MapSeams {
            MapSeams(gatewaySession: server.configuration, connectivity: connectivity, gatewayReadInterval: .milliseconds(20))
        }

        private func newMap() throws -> MaqsMap {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            return try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
        }

        /// A map set up by `configure`, shown at zoom 13 over the `test` region and drawn. Close the host when done.
        private func shownMap(_ configure: (MaqsMap) -> Void = { _ in }) async throws -> (MaqsMap, MapHost) {
            let map = try newMap()
            configure(map)
            let host = try await MapHost.show(map)
            host.mapView.setCenter(TestRegion.center, zoomLevel: 13, animated: false)
            try await host.waitUntilDrawn()
            return (map, host)
        }

        /// `coordinate` moved by the given degrees.
        private func offset(_ coordinate: CLLocationCoordinate2D, lat: Double = 0, lon: Double = 0) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: coordinate.latitude + lat, longitude: coordinate.longitude + lon)
        }

        private func location(_ coordinate: CLLocationCoordinate2D) -> CLLocation {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        private func near(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
            abs(lhs.latitude - rhs.latitude) < 1e-6 && abs(lhs.longitude - rhs.longitude) < 1e-6
        }

        /// The heading turned into −180…180, so north is near 0 from either side.
        private func signed(_ heading: Double) -> Double {
            heading > 180 ? heading - 360 : heading
        }

        /// Waits until MapLibre has drawn a frame with no camera transition running: it becomes idle only then, and runs
        /// the completions of finished transitions in the same frame.
        private func waitForIdle(_ host: MapHost) async throws {
            let coordinator = host.coordinator
            let idles = coordinator.idlesSinceStyleLoad
            host.mapView.triggerRepaint()
            try await waitUntil { coordinator.idlesSinceStyleLoad > idles }
        }

        /// Follows the position from a first fix south of the centre, once the camera has flown there: the next fix then
        /// moves the camera step by step, which cancels any camera animation that runs.
        private func followFromAFirstFix(_ map: MaqsMap, _ host: MapHost) async throws {
            let first = offset(TestRegion.center, lat: -0.004)
            map.follow(.position)
            map.provide(location(first))
            try await waitUntil { near(map.camera.center, first) }
            try await waitForIdle(host)
        }

        // MARK: Camera actions

        @Test func showingBoundsFitsThemAboveABottomInset() async throws {
            let (map, host) = try await shownMap {
                $0.contentInsets = EdgeInsets(top: 0, leading: 0, bottom: 300, trailing: 0)
            }
            defer { host.close() }
            let mapView = host.mapView
            mapView.setNeedsLayout()
            mapView.layoutIfNeeded()
            #expect(mapView.contentInset == UIEdgeInsets(top: 0, left: 0, bottom: 300, right: 0))
            // North-east of where the map starts, and wider than the view shows at zoom 13.
            let bounds = BoundingBox(minLon: 12.26, minLat: 46.11, maxLon: 12.32, maxLat: 46.15)
            let centre = CLLocationCoordinate2D(latitude: 46.13, longitude: 12.29)
            let content = CGRect(x: 0, y: 0, width: mapView.bounds.width, height: mapView.bounds.height - 300)
            let zoom = mapView.zoomLevel

            map.show(bounds)

            try await waitUntil {
                _ = map.camera
                let point = mapView.convert(centre, toPointTo: mapView)
                return abs(point.x - content.midX) < 2 && abs(point.y - content.midY) < 2
            }
            #expect(mapView.zoomLevel < zoom)
            #expect(mapView.convert(centre, toPointTo: mapView).y < mapView.bounds.midY)
            for corner in [CLLocationCoordinate2D(latitude: 46.11, longitude: 12.26),
                           CLLocationCoordinate2D(latitude: 46.15, longitude: 12.32)] {
                #expect(content.insetBy(dx: -1, dy: -1).contains(mapView.convert(corner, toPointTo: mapView)))
            }
        }

        /// SwiftUI's layout direction decides which side leading and trailing are.
        @Test func leadingAndTrailingInsetsFollowARightToLeftLayout() async throws {
            let map = try newMap()
            map.contentInsets = EdgeInsets(top: 10, leading: 100, bottom: 30, trailing: 20)
            let host = try await MapHost.show(map, layoutDirection: .rightToLeft)
            defer { host.close() }

            #expect(host.mapView.contentInset == UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 100))
        }

        /// MapLibre fits a box to the view's size at the call; before the first layout that is no size at all.
        @Test func boundsShownBeforeTheViewHasASizeAreFittedOnceItHasOne() async throws {
            let map = try newMap()
            let host = try await MapHost.show(map, size: .zero)
            defer { host.close() }
            #expect(host.mapView.bounds.isEmpty)
            let bounds = BoundingBox(minLon: 12.26, minLat: 46.11, maxLon: 12.32, maxLat: 46.15)

            map.show(bounds)
            host.resize(to: CGSize(width: 390, height: 600))

            try await host.waitUntilDrawn()
            try await waitForIdle(host)
            let mapView = host.mapView
            let southWest = mapView.convert(CLLocationCoordinate2D(latitude: 46.11, longitude: 12.26), toPointTo: mapView)
            let northEast = mapView.convert(CLLocationCoordinate2D(latitude: 46.15, longitude: 12.32), toPointTo: mapView)
            let width = northEast.x - southWest.x, height = southWest.y - northEast.y
            #expect(width <= mapView.bounds.width + 1 && height <= mapView.bounds.height + 1)
            #expect(width >= mapView.bounds.width * 0.9 || height >= mapView.bounds.height * 0.9,
                    "the box fills the view in one direction: \(width) × \(height) in \(mapView.bounds.size)")
        }

        @Test func pitchStaysWithinSixtyDegreesAndKeepsTheZoom() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            let zoom = host.mapView.zoomLevel

            map.setPitch(80)

            try await waitUntil { abs(map.camera.pitch - 60) < 0.01 }
            #expect(abs(map.camera.zoom - zoom) < 0.01)

            map.setPitch(-10)

            try await waitUntil { abs(map.camera.pitch) < 0.01 }
            #expect(abs(map.camera.zoom - zoom) < 0.01)
        }

        @Test func showingACoordinateWithoutAZoomKeepsTheZoom() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            let zoom = host.mapView.zoomLevel
            let target = offset(TestRegion.center, lat: 0.01, lon: 0.01)

            map.show(target, zoom: nil)

            try await waitUntil { near(map.camera.center, target) }
            #expect(abs(map.camera.zoom - zoom) < 0.01)

            map.show(target, zoom: 15)

            try await waitUntil { abs(map.camera.zoom - 15) < 0.01 }
            #expect(near(map.camera.center, target))
        }

        @Test func resetNorthTurnsTheMapToNorth() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            host.mapView.setDirection(90, animated: false)
            try await waitUntil { abs(map.camera.heading - 90) < 0.01 }

            map.resetNorth()

            try await waitUntil { abs(signed(map.camera.heading)) < 0.01 }
        }

        /// Bad input does nothing at all: MapLibre throws a C++ exception, a crash, for a NaN coordinate, and a call
        /// with a NaN zoom or pitch, which MapLibre would drop, still cancels the camera move under way. So the bad
        /// calls come while a move runs, and the checks wait for idle, when that move, or one bad input started, has
        /// ended.
        @Test func invalidCameraInputIsIgnored() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            let mapView = host.mapView
            let fix = TestRegion.center
            map.provide(location(fix))
            let target = offset(TestRegion.center, lat: 0.01, lon: 0.01)
            map.show(target, zoom: 14)

            map.show(CLLocationCoordinate2D(latitude: .nan, longitude: 12.25), zoom: nil)
            map.show(CLLocationCoordinate2D(latitude: 95, longitude: 12.25), zoom: 14)
            map.show(TestRegion.center, zoom: .nan)
            map.show(BoundingBox(minLon: 12.27, minLat: 46.09, maxLon: 12.23, maxLat: 46.12))
            map.show(BoundingBox(minLon: .nan, minLat: 46.09, maxLon: 12.27, maxLat: 46.12))
            map.show(BoundingBox(minLon: 12.23, minLat: 46.09, maxLon: 12.27, maxLat: 95))
            map.setPitch(.nan)
            map.provide(CLLocation(latitude: .nan, longitude: 12.25))

            try await waitForIdle(host)
            #expect(near(mapView.centerCoordinate, target))
            #expect(abs(mapView.zoomLevel - 14) < 1e-6)
            #expect(mapView.camera.pitch == 0)
            #expect(mapView.userLocation?.location.map { near($0.coordinate, fix) } == true)
        }

        /// The compass, attribution button and logo the map hides are hidden from accessibility too, so VoiceOver
        /// cannot reach MapLibre's own attribution sheet; the user's location stays an element VoiceOver finds.
        /// MapLibre lists the compass and the attribution button among its accessibility children whatever they show;
        /// hidden, UIKit already reports them as no element, but only `accessibilityElementsHidden` takes them out of
        /// the accessibility tree.
        @Test func voiceOverFindsTheLocationButNoneOfTheHiddenOrnaments() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            map.provide(location(TestRegion.center))
            let mapView = host.mapView
            try await waitUntil { mapView.userLocation?.location != nil }

            let elements = try AccessibilityTree.read { AccessibilityTree.elements(in: mapView) }

            let ornaments: [UIView] = [mapView.compassView, mapView.attributionButton, mapView.logoView]
            let found = elements.filter { element in ornaments.contains { $0 === element } }
            #expect(found.isEmpty, "VoiceOver finds \(found.map { $0.accessibilityLabel ?? "?" })")
            for ornament in ornaments {
                #expect(ornament.accessibilityElementsHidden, "\(type(of: ornament)) \(ornament.accessibilityLabel ?? "")")
                #expect(!ornament.isAccessibilityElement)
            }
            #expect(elements.contains { $0 is MLNUserLocationAnnotationView },
                    "no location among \(elements.map { "\(type(of: $0)) \($0.accessibilityLabel ?? "")" })")
        }

        // MARK: Following

        @Test func eachFollowModeIsMapLibresTrackingMode() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            map.provide(location(TestRegion.center))
            let modes: [(FollowMode, MLNUserTrackingMode)] = [
                (.position, .follow), (.heading, .followWithHeading), (.course, .followWithCourse), (.none, .none),
            ]

            for (mode, tracking) in modes {
                map.follow(mode)

                #expect(host.mapView.userTrackingMode == tracking)
                #expect(map.followMode == mode)
            }
        }

        /// A user's pan drops MapLibre's tracking the way `setCenter` does: both set its mode to none, which the
        /// delegate reports.
        @Test func aPanDropsFollowingToNone() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            map.provide(location(TestRegion.center))
            map.follow(.heading)
            #expect(map.followMode == .heading)

            host.mapView.setCenter(offset(TestRegion.center, lat: 0.01), animated: false)

            #expect(host.mapView.userTrackingMode == .none)
            #expect(map.followMode == .none)
        }

        @Test func northUpWhileFollowingTheHeadingStillFollowsThePosition() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            map.provide(location(TestRegion.center))
            map.follow(.heading)

            map.resetNorth()

            #expect(map.followMode == .position)
            #expect(host.mapView.userTrackingMode == .follow)
        }

        @Test func aPitchChangeWhileFollowingSurvivesTheNextFix() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            try await followFromAFirstFix(map, host)

            map.setPitch(45)
            map.provide(location(offset(TestRegion.center, lat: -0.002, lon: 0.003)))

            try await waitForIdle(host)
            #expect(abs(host.mapView.camera.pitch - 45) < 0.01)
            #expect(map.followMode == .position)
        }

        @Test func northUpWhileFollowingSurvivesTheNextFix() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            host.mapView.setDirection(90, animated: false)
            try await followFromAFirstFix(map, host)
            #expect(abs(host.mapView.direction - 90) < 0.01)

            map.resetNorth()
            map.provide(location(offset(TestRegion.center, lat: -0.002, lon: 0.003)))

            try await waitForIdle(host)
            #expect(abs(signed(host.mapView.direction)) < 0.01)
            #expect(map.followMode == .position)
        }

        /// MapLibre would show the location itself to follow it, against the app's `.hidden`.
        @Test func followingNeedsTheLocationShown() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }

            map.follow(.position)

            #expect(map.followMode == .none)
            #expect(host.mapView.userTrackingMode == .none)
            #expect(!host.mapView.showsUserLocation)
        }

        @Test func aFollowModeChosenBeforeTheViewShowsIsTheViews() async throws {
            let map = try newMap()
            map.userLocation = .provided
            map.follow(.course)
            #expect(map.followMode == .course)

            let host = try await MapHost.show(map)
            defer { host.close() }

            #expect(host.mapView.userTrackingMode == .followWithCourse)
            #expect(map.followMode == .course)
        }

        @Test func hidingTheLocationStopsFollowing() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            map.follow(.position)

            map.userLocation = .hidden

            #expect(map.followMode == .none)
            #expect(host.mapView.userTrackingMode == .none)
        }

        // MARK: The user's location

        @Test func providedLocationsMoveTheUsersLocationToTheLastFix() async throws {
            let (map, host) = try await shownMap { $0.userLocation = .provided }
            defer { host.close() }
            let manager = try #require(host.mapView.locationManager as? ProvidedLocationManager)
            #expect(manager.authorizationStatus == .authorizedWhenInUse)
            #expect(host.mapView.showsUserLocation)
            let second = offset(TestRegion.center, lat: 0.002, lon: 0.003)

            map.provide(location(TestRegion.center))
            map.provide(location(second))

            let shown = try #require(host.mapView.userLocation?.location)
            #expect(near(shown.coordinate, second))
        }

        /// The spy stands in for MapLibre's own manager before the app has asked: MapLibre asks it for permission only
        /// when `shouldRequestAuthorizationToUseLocationServices` is true and the status is not determined.
        @Test func theMapNeverAsksForLocationPermission() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            #expect(!host.mapView.shouldRequestAuthorizationToUseLocationServices)
            let spy = SpyLocationManager()
            host.mapView.locationManager = spy

            map.userLocation = .system
            for mode in [FollowMode.position, .heading, .course, .none] { map.follow(mode) }
            for mode in [UserLocationMode.provided, .system, .hidden, .system] { map.userLocation = mode }

            #expect(host.mapView.showsUserLocation)
            #expect(host.mapView.locationManager === spy)
            #expect(spy.locationStarts > 0)
            #expect(spy.authorizationRequests == 0)
        }

        /// The manager of each mode is the one installed and running: MapLibre starts a manager only when the location
        /// turns on, and stops the one it replaces.
        @Test func locationModesSwitchInAnyOrder() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            let system = SpyLocationManager()
            host.mapView.locationManager = system
            let order: [UserLocationMode] = [.provided, .system, .provided, .hidden, .system, .hidden, .provided, .hidden,
                                             .provided]

            for mode in order {
                map.userLocation = mode

                let provided = host.mapView.locationManager as? ProvidedLocationManager
                switch mode {
                case .hidden:
                    #expect(!host.mapView.showsUserLocation)
                case .system:
                    #expect(host.mapView.showsUserLocation)
                    #expect(host.mapView.locationManager === system)
                    #expect(system.isUpdatingLocation)
                case .provided:
                    #expect(host.mapView.showsUserLocation)
                    #expect(provided?.isUpdatingLocation == true)
                    #expect(!system.isUpdatingLocation)
                }
            }
            let fix = offset(TestRegion.center, lat: 0.001)
            map.provide(location(fix))
            #expect(host.mapView.userLocation?.location.map { near($0.coordinate, fix) } == true)
        }

        @Test func switchingTheLocationSourceKeepsFollowing() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            let system = SpyLocationManager()
            host.mapView.locationManager = system
            map.userLocation = .provided
            map.provide(location(TestRegion.center))
            map.follow(.position)

            map.userLocation = .system

            #expect(host.mapView.locationManager === system)
            #expect(map.followMode == .position)
            #expect(host.mapView.userTrackingMode == .follow)
        }

        /// MapLibre turns its location off when the system denies it, and does not turn it on again when the user
        /// allows it later; with `.system` the map does.
        @Test func aLocationAllowedAfterADenialComesBack() async throws {
            let (map, host) = try await shownMap()
            defer { host.close() }
            let spy = SpyLocationManager()
            host.mapView.locationManager = spy
            map.userLocation = .system
            spy.deny()
            #expect(!host.mapView.showsUserLocation)

            spy.allow()

            #expect(host.mapView.showsUserLocation)
            #expect(host.mapView.locationManager === spy)
        }

        // MARK: Taps on the user's location

        /// MapLibre's own single tap begins over the user's location and selects it; the map's tap recognizes with it,
        /// so a tap there still reaches `onTap`. Real touches are checked in the demo.
        @Test func theMapsTapRecognizesAlongsideMapLibresAnnotationTap() async throws {
            let map = try newMap()
            let host = try await MapHost.show(map)
            defer { host.close() }
            let coordinator = host.coordinator
            let ours = coordinator.tapRecognizer
            let taps = (host.mapView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            let mapLibreTap = try #require(taps.first {
                $0 !== ours && $0.numberOfTapsRequired == 1 && $0.numberOfTouchesRequired == 1
            })
            let doubleTap = try #require(taps.first { $0.numberOfTapsRequired == 2 && $0.numberOfTouchesRequired == 1 })
            // An app's own single tap on a view around the map.
            let appTap = UITapGestureRecognizer()
            try #require(host.mapView.superview).addGestureRecognizer(appTap)

            #expect(ours.delegate === coordinator)
            #expect(coordinator.gestureRecognizer(ours, shouldRecognizeSimultaneouslyWith: mapLibreTap))
            #expect(!coordinator.gestureRecognizer(ours, shouldRecognizeSimultaneouslyWith: doubleTap))
            #expect(!coordinator.gestureRecognizer(ours, shouldRecognizeSimultaneouslyWith: appTap))
        }

        // MARK: Connectivity

        @Test func goingOfflineSendsNoTileOnlineUntilTheNetworkIsBack() async throws {
            let (updates, connectivity) = AsyncStream<Connectivity>.makeStream()
            connectivity.yield(.online)
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams { updates })
            try await waitUntil { map.styles != nil }
            let template = try #require(await maqs.onlineSources?.basemap.first?.tiles)
            let url = try #require(URL(string: template
                .replacingOccurrences(of: "{z}", with: "14").replacingOccurrences(of: "{x}", with: "8749")
                .replacingOccurrences(of: "{y}", with: "5822")))
            server.route(url, body: Data([1, 2, 3]))
            let mapLibre = URLSessionConfiguration.ephemeral
            mapLibre.protocolClasses = [TileGateway.self]
            let session = URLSession(configuration: mapLibre)
            let server = server
            func asked() -> Int { server.requests.filter { $0.url == url }.count }

            _ = try await session.data(from: url)
            #expect(asked() == 1)

            connectivity.yield(.offline)
            try await waitUntil { map.connectivity == .offline }
            await #expect(throws: URLError.self) { _ = try await session.data(from: url) }
            #expect(asked() == 1)

            connectivity.yield(.online)
            try await waitUntil { map.connectivity == .online }
            _ = try await session.data(from: url)
            #expect(asked() == 2)
        }
    }
}

/// A location manager that counts what MapLibre asks of it, standing in for MapLibre's own manager. Its status starts
/// not determined, as before the app's prompt.
@MainActor private final class SpyLocationManager: NSObject, @preconcurrency MLNLocationManager {
    weak var delegate: (any MLNLocationManagerDelegate)?
    var headingOrientation: CLDeviceOrientation = .portrait
    private(set) var authorizationStatus = CLAuthorizationStatus.notDetermined
    private(set) var authorizationRequests = 0
    private(set) var locationStarts = 0
    private(set) var isUpdatingLocation = false

    /// Reports what Core Location reports to a running manager when the user denies the location.
    func deny() {
        authorizationStatus = .denied
        delegate?.locationManager(self, didFailWithError: CLError(.denied))
    }

    /// Reports what Core Location reports when the user allows the location later, in Settings.
    func allow() {
        authorizationStatus = .authorizedWhenInUse
        delegate?.locationManagerDidChangeAuthorization(self)
    }

    func requestAlwaysAuthorization() { authorizationRequests += 1 }

    func requestWhenInUseAuthorization() { authorizationRequests += 1 }

    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String) { authorizationRequests += 1 }

    func startUpdatingLocation() {
        locationStarts += 1
        isUpdatingLocation = true
    }

    func stopUpdatingLocation() { isUpdatingLocation = false }

    func startUpdatingHeading() {}

    func stopUpdatingHeading() {}

    func dismissHeadingCalibrationDisplay() {}
}
#endif
