#if canImport(MapLibre)
import Foundation
import MaqsTestSupport
import SwiftUI
import Testing
import UIKit

@testable import MaqsCore
@testable import MaqsUI

extension SharedGatewaySuite {
    /// `MaqsMap.credits` for what a real map draws over the `test` region's fixtures, and `MapAttributionView` as
    /// VoiceOver reads it: the accessibility tree of its hosting controller, in a key window the test creates.
    @MainActor @Suite(.timeLimit(.minutes(1))) struct MapAttributionTests {
        private let server = StubServer()
        private let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
            GatewayState.shared.resetForTesting()
            NetworkTripwire.reset()
        }

        private func seams() -> MapSeams {
            MapSeams(
                gatewaySession: server.configuration, connectivity: { AsyncStream { $0.yield(.online) } },
                gatewayReadInterval: .milliseconds(20))
        }

        // The fixture manifest's credits. The bundled `sources.json` names the same texts, without links.
        private static let osm = MapCredit(
            text: "© OpenStreetMap contributors", url: URL(string: "https://www.openstreetmap.org/copyright"))
        private static let esa = MapCredit(
            text: "CC BY 4.0 ESA WorldCover 2021", url: URL(string: "https://esa-worldcover.org/en/data-access"))
        private static let mapterhorn = MapCredit(
            text: "© Mapterhorn", url: URL(string: "https://mapterhorn.com/attribution"))

        /// A map with nothing installed and no catalog: the online sources' credits, none with a link.
        private func onlineMap(layers: Set<Layer> = [.basemap, .terrain], onlineTiles: Bool = true) throws
            -> (maqs: Maqs, map: MaqsMap) {
            let maqs = try TestRegion.maqs(on: server, layers: layers, in: directory, onlineTiles: onlineTiles)
            return (maqs, try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams()))
        }

        // MARK: Credits

        @Test func theHeadlineMapCreditsItsBasemapHillshadeTrailsAndPlaces() async throws {
            let maqs = try await TestRegion.installEveryMapLayer(on: server, in: directory)
            let map = try TestRegion.mapShowingEveryOverlay(maqs, seams: seams())

            try await waitUntil { !map.credits.isEmpty }

            #expect(map.credits == [Self.osm, Self.esa, Self.mapterhorn])
            #expect(map.creditInputs?.drawn == [.basemap, .terrain, .trails, .places])
            #expect(map.creditInputs?.installed == [.basemap, .terrain, .trails, .places])
            // The fixture manifest credits trails and places only with OpenStreetMap's entry, which the basemap lists
            // as well, so this shows the entry is there, not that the overlays add it: the next test shows that.
            let overlayCredits = try #require(maqs.state.catalog?.attribution)
                .filter { $0.layers.contains(.trails) || $0.layers.contains(.places) }
                .map { MapCredit(text: $0.text, url: $0.url) }
            #expect(overlayCredits == [Self.osm])
            #expect(map.uncreditedLayers.isEmpty)
        }

        /// With credits of their own in the manifest, the overlays add them while they show, and only then.
        @Test func shownOverlaysAddTheirOwnManifestCredits() async throws {
            let trails = MapCredit(text: "Trails test credit", url: URL(string: "https://example.org/trails"))
            let places = MapCredit(text: "Places test credit", url: URL(string: "https://example.org/places"))
            let manifest = try Fixtures.manifestJSON { object in
                var attribution = object["attribution"] as? [[String: Any]] ?? []
                for (credit, layer) in [(trails, "trails"), (places, "places")] {
                    attribution.append([
                        "text": credit.text, "licence": "test", "url": credit.url?.absoluteString ?? "",
                        "layers": [layer],
                    ])
                }
                object["attribution"] = attribution
            }
            let maqs = try await TestRegion.installEveryMapLayer(on: server, in: directory, manifest: manifest)
            let map = try TestRegion.mapShowingEveryOverlay(maqs, seams: seams())
            try await waitUntil { !map.credits.isEmpty }
            #expect(map.credits == [Self.osm, Self.esa, Self.mapterhorn, trails, places])

            map.overlays = MapOverlays()

            #expect(map.credits == [Self.osm, Self.esa, Self.mapterhorn])
        }

        @Test func withHillshadeOffMapterhornIsGone() async throws {
            let maqs = try await TestRegion.installEveryMapLayer(on: server, in: directory)
            let map = try TestRegion.mapShowingEveryOverlay(maqs, seams: seams())
            try await waitUntil { map.credits.contains(Self.mapterhorn) }

            map.configuration.showsHillshade = false

            #expect(map.credits == [Self.osm, Self.esa])
            #expect(map.creditInputs?.drawn == [.basemap, .trails, .places])
        }

        /// No pack changes when the catalog arrives with nothing installed, yet the credits gain the manifest's links.
        @Test func aCatalogChangeUpdatesTheCredits() async throws {
            let (maqs, map) = try onlineMap(layers: [.basemap])
            try await waitUntil { !map.credits.isEmpty }
            #expect(map.credits == [MapCredit(text: Self.osm.text, url: nil), MapCredit(text: Self.esa.text, url: nil)])
            try Fixtures.serveRelease(on: server)

            _ = try await maqs.refreshCatalog()

            try await waitUntil { map.credits.first?.url != nil }
            #expect(map.credits == [Self.osm, Self.esa])
        }

        /// With online tiles off and nothing installed the basemap has no credit: the map reports it (and logs it),
        /// with no credit made up, until the installed region's manifest entries credit it.
        @Test func aDrawnLayerWithNoCreditIsReportedUntilItGetsOne() async throws {
            let (maqs, map) = try onlineMap(layers: [.basemap], onlineTiles: false)
            try await waitUntil { map.styles != nil }
            #expect(map.credits.isEmpty)
            #expect(map.uncreditedLayers == [.basemap])
            try Fixtures.serveRelease(on: server)

            _ = try await maqs.refreshCatalog()
            try await maqs.install(TestRegion.id)

            try await waitUntil { !map.credits.isEmpty }
            #expect(map.credits == [Self.osm, Self.esa])
            #expect(map.uncreditedLayers.isEmpty)
        }

        // MARK: The view

        /// `MapAttributionView` in a hosting controller, in a key window `width` points wide, laid out at `size`. Hide
        /// the window when the test ends.
        private func show(_ map: MaqsMap, width: CGFloat = 390, size: DynamicTypeSize = .large) -> UIWindow {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 400))
            window.rootViewController = UIHostingController(
                rootView: MapAttributionView(map: map).environment(\.dynamicTypeSize, size))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            return window
        }

        private func close(_ window: UIWindow) {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// What VoiceOver finds in `window`, with the credits button activated `taps` times first, as VoiceOver
        /// activates it.
        private func accessibilityElements(in window: UIWindow, afterActivating taps: Int = 0) throws -> [NSObject] {
            try AccessibilityTree.read {
                for _ in 0..<taps {
                    let button = try #require(AccessibilityTree.elements(in: window)
                        .first { $0.accessibilityLabel == "Map data credits" })
                    #expect(button.accessibilityActivate())
                }
                return AccessibilityTree.elements(in: window)
            }
        }

        private var buttonAndEveryCredit: [String] {
            ["Map data credits", Self.osm.text, Self.esa.text, Self.mapterhorn.text]
        }

        @Test func collapsedTheViewIsTheCreditsButtonAndTheFirstCredit() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let window = show(map)
            defer { close(window) }

            let elements = try accessibilityElements(in: window)

            #expect(elements.map(\.accessibilityLabel) == ["Map data credits", Self.osm.text])
            #expect(elements.first?.accessibilityTraits.contains(.button) == true)
            #expect(elements.last?.accessibilityTraits.contains(.staticText) == true)
        }

        @Test func expandedEveryCreditIsItsOwnLinkWhenItHasAPage() async throws {
            let maqs = try await TestRegion.installEveryMapLayer(on: server, in: directory)
            let map = try TestRegion.mapShowingEveryOverlay(maqs, seams: seams())
            try await waitUntil { map.credits.count == 3 }
            let window = show(map)
            defer { close(window) }

            let elements = try accessibilityElements(in: window, afterActivating: 1)

            #expect(elements.map(\.accessibilityLabel) == buttonAndEveryCredit)
            #expect(elements.dropFirst().allSatisfy { $0.accessibilityTraits.contains(.link) })
        }

        @Test func expandedACreditWithoutAPageIsText() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let window = show(map)
            defer { close(window) }

            let elements = try accessibilityElements(in: window, afterActivating: 1)

            #expect(elements.map(\.accessibilityLabel) == buttonAndEveryCredit)
            #expect(elements.dropFirst().allSatisfy {
                $0.accessibilityTraits.contains(.staticText) && !$0.accessibilityTraits.contains(.link)
            })
        }

        @Test func theButtonCollapsesTheViewAgain() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let window = show(map)
            defer { close(window) }

            #expect(try accessibilityElements(in: window, afterActivating: 2).map(\.accessibilityLabel)
                == ["Map data credits", Self.osm.text])
        }

        @Test func withNoCreditsTheViewIsTheButtonAlone() async throws {
            let map = try onlineMap(layers: [.basemap], onlineTiles: false).map
            try await waitUntil { map.styles != nil }
            let window = show(map)
            defer { close(window) }

            #expect(try accessibilityElements(in: window).map(\.accessibilityLabel) == ["Map data credits"])
        }

        /// The button's touch target is at least 44 points square, whatever the size of the symbol in it.
        @Test func theButtonIsAtLeast44PointsOnBothAxes() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let window = show(map, size: .xSmall)
            defer { close(window) }

            let button = try #require(try accessibilityElements(in: window).first)

            #expect(button.accessibilityLabel == "Map data credits")
            // The accessibility frame is in screen coordinates, whose conversion can lose the last bits: 44 reads back
            // as 43.999999999999986.
            let frame = button.accessibilityFrame.insetBy(dx: -0.001, dy: -0.001)
            #expect(frame.width >= 44 && frame.height >= 44, "the button's frame is \(button.accessibilityFrame)")
        }

        @Test func theButtonSaysWhetherTheCreditsAreExpanded() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let window = show(map)
            defer { close(window) }

            #expect(try accessibilityElements(in: window).first?.accessibilityValue == "Collapsed")
            #expect(try accessibilityElements(in: window, afterActivating: 1).first?.accessibilityValue == "Expanded")
            #expect(try accessibilityElements(in: window, afterActivating: 1).first?.accessibilityValue == "Collapsed")
        }

        /// The height of the first credit's text, shown `width` points wide at `size`.
        private func firstCreditHeight(of map: MaqsMap, width: CGFloat, size: DynamicTypeSize) throws -> CGFloat {
            let window = show(map, width: width, size: size)
            defer { close(window) }
            let credit = try #require(try accessibilityElements(in: window)
                .first { $0.accessibilityLabel == Self.osm.text })
            return credit.accessibilityFrame.height
        }

        @Test func theCreditTextScalesWithDynamicType() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }

            #expect(try firstCreditHeight(of: map, width: 1200, size: .accessibility3)
                > firstCreditHeight(of: map, width: 1200, size: .xSmall))
        }

        /// At an accessibility size a long credit takes more than one line in a narrow view, rather than being cut.
        @Test func aLongCreditWrapsAtALargeTextSize() async throws {
            let map = try onlineMap().map
            try await waitUntil { map.credits.count == 3 }
            let oneLine = try firstCreditHeight(of: map, width: 1200, size: .accessibility3)

            #expect(try firstCreditHeight(of: map, width: 160, size: .accessibility3) > oneLine * 1.5)
        }
    }
}
#endif
