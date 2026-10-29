#if canImport(MapLibre)
import CoreLocation
import Foundation
import MapLibre
import MaqsData
import MaqsTestSupport
import SwiftUI
import Testing
import UIKit

@testable import MaqsCore
@testable import MaqsUI

extension SharedGatewaySuite {
    /// The app's lines and markers, the selected trail and taps, on real MapLibre views. The overlays come from the
    /// installed `test` region; tiles outside it go to a stub server that answers 404.
    @MainActor @Suite(.timeLimit(.minutes(1))) struct MapContentTests {
        private let server = StubServer()
        private let directory: TemporaryDirectory
        /// The `test` region's box, `[12.21, 46.08, 12.29, 46.13]`.
        private let box: QueryArea

        init() throws {
            directory = try TemporaryDirectory()
            box = try QueryArea(minLongitude: 12.21, minLatitude: 46.08, maxLongitude: 12.29, maxLatitude: 46.13)
            GatewayState.shared.resetForTesting()
            NetworkTripwire.reset()
        }

        private func seams() -> MapSeams {
            MapSeams(
                gatewaySession: server.configuration, connectivity: { AsyncStream { $0.yield(.online) } },
                gatewayReadInterval: .milliseconds(20))
        }

        /// `coordinate` moved by the given degrees.
        private func offset(_ coordinate: CLLocationCoordinate2D, lat: Double = 0, lon: Double = 0) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: coordinate.latitude + lat, longitude: coordinate.longitude + lon)
        }

        /// The features of a content source in the tiles MapLibre has drawn, by `maqs_id`: one that crosses a tile edge
        /// comes back once per tile. The source's `shape` cannot tell: MapLibre holds the wrapper of a source from the
        /// style JSON weakly, so every lookup makes a new one, without the shape set on the last.
        private func features(_ style: MLNStyle, _ source: String) -> [String: any MLNFeature] {
            let all = (style.source(withIdentifier: source) as? MLNShapeSource)?.features(matching: nil) ?? []
            return Dictionary(all.compactMap { feature in
                (feature.attribute(forKey: "maqs_id") as? String).map { ($0, feature) }
            }, uniquingKeysWith: { first, _ in first })
        }

        /// The image names the drawn features of `maqs-markers` refer to.
        private func markerImageNames(_ style: MLNStyle) -> [String] {
            features(style, "maqs-markers").values.compactMap { $0.attribute(forKey: "maqs_image") as? String }
        }

        /// The filter of the test region's selected-trail layer, as style JSON.
        private func selectionFilter(_ host: MapHost) throws -> NSArray? {
            let layer = try #require(host.mapView.style?.layer(withIdentifier: "maqs-trails-test-selected") as? MLNLineStyleLayer)
            return layer.predicate?.mgl_jsonExpressionObject as? NSArray
        }

        /// The installed file of `layer`'s reader (not the overlay).
        private func readerFile(_ maqs: Maqs, _ layer: Layer) async throws -> URL {
            try #require(await maqs.installedPack(TestRegion.id)?.files[layer]?.first { $0.role == nil }?.url)
        }

        /// The first trail `MaqsData` lists in the region, and a point of its path inside the region's box.
        private func firstTrail(_ trails: Trails) async throws -> (TrailSummary, CLLocationCoordinate2D) {
            let first = try #require(await trails.trails(in: box).first)
            let trail = try #require(await trails.trail(region: first.region, featureID: first.featureID))
            let inside = trail.path.joined().filter {
                (box.minLatitude...box.maxLatitude).contains($0.latitude)
                    && (box.minLongitude...box.maxLongitude).contains($0.longitude)
            }
            try #require(!inside.isEmpty, "the first trail has no point inside the test region")
            return (first, inside[inside.count / 2])
        }

        private func point(_ host: MapHost, _ coordinate: CLLocationCoordinate2D) -> CGPoint {
            host.mapView.convert(coordinate, toPointTo: host.mapView)
        }

        @Test func contentSurvivesAStyleLoad() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(accent: .orange), seams: seams())
            let center = TestRegion.center
            map.lines = [
                MapLine(id: "route", coordinates: [offset(center, lon: -0.01), offset(center, lon: 0.01)]),
                MapLine(id: "track", coordinates: [offset(center, lat: -0.01), offset(center, lat: 0.01)], style: .hidden),
            ]
            map.activeLineID = "route"
            map.markers = [
                MapMarker(id: "start", coordinate: offset(center, lon: -0.01), content: .count(1)),
                MapMarker(id: "trail", coordinate: center, content: .plate("926"), label: "Col Visentin"),
                MapMarker(id: "end", coordinate: offset(center, lon: 0.01), isHidden: true),
            ]
            map.selectedMarkerID = "start"
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(center, zoomLevel: 13, animated: false)
            try await host.waitUntilDrawn()
            let coordinator = host.coordinator
            #expect(coordinator.loadedStyle == map.styles?.light)
            let lightNames = Set(markerImageNames(try #require(host.mapView.style)))
            let loads = coordinator.styleLoads

            host.setInterfaceStyle(.dark)

            try await waitUntil {
                coordinator.styleLoads > loads && coordinator.loadedStyle == map.styles?.dark
                    && coordinator.idlesSinceStyleLoad > 0
            }
            let style = try #require(host.mapView.style)
            #expect(features(style, "maqs-lines").count == 2)
            #expect(features(style, "maqs-markers").count == 3)
            let darkNames = markerImageNames(style)
            #expect(darkNames.count == 3)
            #expect(lightNames.count == 3 && lightNames.isDisjoint(with: darkNames))
            for name in darkNames {
                #expect(style.image(forName: name) != nil, "\(name) is not in the style")
            }
            let accent = UIColor(Color.orange).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            #expect(darkNames.contains(MarkerImages.name(for: .count(1), hidden: false, selected: true, accent: accent, dark: true)))
            for kind in MarkerImages.placeKinds + ["other"] {
                #expect(style.image(forName: MarkerImages.placeKindName(kind, dark: true)) != nil)
            }
            #expect(style.image(forName: MarkerImages.plateName(dark: true)) != nil)
        }

        @Test func changedContentReplacesTheShapesWithoutAStyleLoad() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let host = try await MapHost.show(map)
            defer { host.close() }
            let center = TestRegion.center
            host.mapView.setCenter(center, zoomLevel: 13, animated: false)
            try await host.waitUntilDrawn()
            let coordinator = host.coordinator
            let loads = coordinator.styleLoads
            let idles = coordinator.idlesSinceStyleLoad

            map.lines = [MapLine(id: "route", coordinates: [center, offset(center, lon: 0.01)])]
            map.markers = [MapMarker(id: "a", coordinate: center), MapMarker(id: "b", coordinate: offset(center, lat: 0.01))]
            map.selectedMarkerID = "b"

            try await waitUntil { coordinator.idlesSinceStyleLoad > idles }
            let style = try #require(host.mapView.style)
            #expect(features(style, "maqs-lines").count == 1)
            let names = markerImageNames(style)
            #expect(names.count == 2 && Set(names).count == 2)
            for name in names {
                #expect(style.image(forName: name) != nil, "\(name) is not in the style")
            }
            #expect(host.coordinator.styleLoads == loads)
        }

        @Test func aTapOnAFixtureTrailReturnsTheRowMaqsDataReads() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .trails], in: directory)
            let trails = try Trails(files: [try await readerFile(maqs, .trails)])
            let (first, onTrail) = try await firstTrail(trails)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(trails: true)
            var taps: [MapTap] = []
            map.onTap = { taps.append($0) }
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(onTrail, zoomLevel: 14, animated: false)
            try await host.waitForStyle { $0.layer(withIdentifier: "maqs-trails-test-line") != nil }
            try await host.waitUntilDrawn()

            host.coordinator.tap(at: point(host, onTrail))

            let tap = try #require(taps.first)
            #expect(taps.count == 1)
            #expect(abs(tap.coordinate.latitude - onTrail.latitude) < 1e-5)
            #expect(abs(tap.coordinate.longitude - onTrail.longitude) < 1e-5)
            let features = tap.hits.compactMap { hit -> OverlayFeature? in
                if case .trail(let feature) = hit { feature } else { nil }
            }
            #expect(Set(features).count == features.count, "a trail is hit once, whatever the tiles")
            let feature = try #require(features.first { $0.featureID == first.featureID })
            #expect(feature.region == "test")
            let read = try #require(await trails.trail(region: feature.region, featureID: feature.featureID))
            #expect(read.summary.id == first.id)
        }

        @Test func aTapOnAFixturePlaceReturnsTheRowMaqsDataReads() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .places], in: directory)
            let places = try Places(files: [try await readerFile(maqs, .places)])
            let first = try #require(await places.places(in: box).first)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(places: nil)
            var taps: [MapTap] = []
            map.onTap = { taps.append($0) }
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(first.coordinate, zoomLevel: 14, animated: false)
            try await host.waitForStyle { $0.layer(withIdentifier: "maqs-places-test-markers") != nil }
            try await host.waitUntilDrawn()

            host.coordinator.tap(at: point(host, first.coordinate))

            let hits = try #require(taps.first).hits
            #expect(hits.contains(.place(OverlayFeature(region: "test", featureID: first.featureID))))
            #expect(!hits.contains { if case .trail = $0 { true } else { false } })
            let read = try #require(await places.place(region: "test", featureID: first.featureID))
            #expect(read == first)
        }

        /// Settlements are a name only, below the base map's labels. Where the overlay draws a name, a tap on it reports
        /// the place. Where the base map labels the same settlement, the overlay's name gives way and draws nothing to
        /// tap, so the test taps a name the overlay drew, at zoom 12, below the base map's hamlet labels (zoom 13).
        @Test func aTapOnAFixtureSettlementNameReturnsThePlace() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .places], in: directory)
            let places = try Places(files: [try await readerFile(maqs, .places)])
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(places: nil)
            var taps: [MapTap] = []
            map.onTap = { taps.append($0) }
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(TestRegion.center, zoomLevel: 12, animated: false)
            try await host.waitForStyle { $0.layer(withIdentifier: "maqs-places-test-names") != nil }
            try await host.waitUntilDrawn()
            let names = host.mapView.visibleFeatures(in: host.mapView.bounds, styleLayerIdentifiers: ["maqs-places-test-names"])
            let drawn = try #require(names.first, "the overlay drew no settlement name")
            let featureID = try #require((drawn.attribute(forKey: "id") as? NSNumber)?.int64Value)

            host.coordinator.tap(at: point(host, drawn.coordinate))

            let hits = try #require(taps.first).hits
            #expect(hits.contains(.place(OverlayFeature(region: "test", featureID: featureID))))
            let read = try #require(await places.place(region: "test", featureID: featureID))
            #expect([PlaceKind.village, .hamlet, .isolatedDwelling].contains(read.kind))
        }

        @Test func aSelectedTrailIsDrawnInTheAccentLayerOnly() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .trails], in: directory)
            let trails = try Trails(files: [try await readerFile(maqs, .trails)])
            let (first, onTrail) = try await firstTrail(trails)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(trails: true)
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(onTrail, zoomLevel: 14, animated: false)
            try await host.waitForStyle { $0.layer(withIdentifier: "maqs-trails-test-selected") != nil }
            try await host.waitUntilDrawn()
            let coordinator = host.coordinator
            #expect(try selectionFilter(host) == ["==", ["get", "id"], -1])
            let idles = coordinator.idlesSinceStyleLoad

            map.selectedOverlayFeature = OverlayFeature(region: "test", featureID: first.featureID)

            #expect(try selectionFilter(host) == ["==", ["get", "id"], first.featureID])
            try await waitUntil { coordinator.idlesSinceStyleLoad > idles }
            let drawn = host.mapView.visibleFeatures(in: host.mapView.bounds, styleLayerIdentifiers: ["maqs-trails-test-selected"])
            #expect(!drawn.isEmpty)
            #expect(drawn.allSatisfy { ($0.attribute(forKey: "id") as? NSNumber)?.int64Value == first.featureID })

            map.selectedOverlayFeature = OverlayFeature(region: "veneto", featureID: first.featureID)
            #expect(try selectionFilter(host) == ["==", ["get", "id"], -1])

            map.selectedOverlayFeature = OverlayFeature(region: "test", featureID: first.featureID)
            let loads = coordinator.styleLoads
            host.setInterfaceStyle(.dark)
            try await waitUntil { coordinator.styleLoads > loads && coordinator.loadedStyle == map.styles?.dark }
            #expect(try selectionFilter(host) == ["==", ["get", "id"], first.featureID])

            map.selectedOverlayFeature = nil
            #expect(try selectionFilter(host) == ["==", ["get", "id"], -1])
        }

        @Test func aTapOnAMarkerAndALineReturnsBothTopmostFirst() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let center = TestRegion.center
            map.lines = [MapLine(id: "route", coordinates: [offset(center, lon: -0.02), offset(center, lon: 0.02)])]
            map.markers = [MapMarker(id: "summit", coordinate: center)]
            var taps: [MapTap] = []
            map.onTap = { taps.append($0) }
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(center, zoomLevel: 14, animated: false)
            try await host.waitUntilDrawn()

            host.coordinator.tap(at: point(host, center))
            host.coordinator.tap(at: CGPoint(x: 30, y: 30))

            #expect(taps.map(\.hits) == [[.marker("summit"), .line("route")], []])
        }

        @Test func theMapHasASingleTapRecognizerOfItsOwn() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let host = try await MapHost.show(map)
            defer { host.close() }

            let recognizer = host.coordinator.tapRecognizer
            #expect(recognizer.view === host.mapView)
            #expect(recognizer.numberOfTapsRequired == 1 && recognizer.numberOfTouchesRequired == 1)
            #expect(recognizer.isEnabled)
        }
    }
}
#endif
