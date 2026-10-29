import CoreLocation
import Foundation
import MaqsTestSupport
import Testing

@testable import MaqsCore
@testable import MaqsUI

@Suite struct RegionOfferTests {
    // Nested boxes: triveneto contains veneto contains test; "outside" is far away.
    private static let regions: [(id: String, bbox: [Double])] = [
        ("triveneto", [10.0, 44.5, 14.0, 47.0]),
        ("veneto", [11.0, 45.0, 13.0, 46.5]),
        ("test", [12.21, 46.08, 12.29, 46.13]),
    ]

    private func catalog(installed: [PackID: InstalledPack] = [:]) throws -> Catalog {
        let data = try Fixtures.manifestJSON { object in
            var list = object["regions"] as! [[String: Any]]
            let template = list[0]
            list = Self.regions.map { entry in
                var region = template
                region["id"] = entry.id
                region["bbox"] = entry.bbox
                // File names are unique across a manifest, so each copy gets its own.
                var layers = region["layers"] as! [String: [[String: Any]]]
                for (layer, entries) in layers {
                    layers[layer] = entries.map { item in
                        var item = item
                        for key in ["file", "url"] {
                            item[key] = (item[key] as! String).replacingOccurrences(of: "test-", with: "\(entry.id)-")
                        }
                        return item
                    }
                }
                region["layers"] = layers
                return region
            }
            object["regions"] = list
            object["base"] = []
        }
        let manifest = try Manifest.decode(data, manifestHost: "github.com")
        return CatalogBuilder.build(
            manifest: manifest, fetchedAt: Date(timeIntervalSince1970: 0), layers: [.trails], installed: installed)
    }

    private func installedPack(_ id: String, in catalog: Catalog) throws -> InstalledPack {
        // Files matching the catalog's manifest entries, so the status is `.installed`.
        let data = try Fixtures.manifestData()
        let manifest = try Manifest.decode(data, manifestHost: "github.com")
        let entries = manifest.regions[0].entries(for: .trails)!
        let files = entries.map {
            InstalledFile(
                url: URL(filePath: "/x/\($0.file)"), role: $0.role, schemaVersion: 1, sha256: $0.sha256, bytes: $0.bytes,
                dataDate: $0.dataDate)
        }
        return InstalledPack(id: .region(id), release: "data-ci", files: [.trails: files], bundled: false)
    }

    private func status(_ catalog: Catalog, _ id: String) -> PackStatus { catalog.pack(.region(id))!.status }

    private let nevegal = CLLocationCoordinate2D(latitude: 46.10, longitude: 12.25)
    private let padova = CLLocationCoordinate2D(latitude: 45.4, longitude: 11.9)

    @Test func nothingWhenTheCentreIsInNoRegion() throws {
        let centre = CLLocationCoordinate2D(latitude: 40, longitude: 0)
        #expect(RegionOffer.region(at: centre, catalog: try catalog(), packs: [:]) == nil)
    }

    @Test func offersTheSmallestContainingRegion() throws {
        let offer = RegionOffer.region(at: padova, catalog: try catalog(), packs: [:])
        #expect(offer?.id == .region("veneto"))
        let inner = RegionOffer.region(at: nevegal, catalog: try catalog(), packs: [:])
        #expect(inner?.id == .region("test"))
    }

    @Test func nothingWhenALargerRegionIsInstalled() throws {
        let base = try catalog()
        let installed = try catalog(installed: [.region("triveneto"): try installedPack("triveneto", in: base)])
        #expect(status(installed, "triveneto") != .notInstalled)
        #expect(RegionOffer.region(at: padova, catalog: installed, packs: [:]) == nil)
    }

    @Test func nothingWhenTheInstalledRegionHasAnUpdate() throws {
        let base = try catalog()
        var pack = try installedPack("veneto", in: base)
        pack = InstalledPack(
            id: pack.id, release: "data-old",
            files: pack.files.mapValues { $0.map { InstalledFile(url: $0.url, role: $0.role, schemaVersion: 1, sha256: "00", bytes: $0.bytes, dataDate: $0.dataDate) } },
            bundled: false)
        let outdated = try catalog(installed: [.region("veneto"): pack])
        guard case .updateAvailable = status(outdated, "veneto") else {
            Issue.record("expected updateAvailable, got \(status(outdated, "veneto"))")
            return
        }
        #expect(RegionOffer.region(at: padova, catalog: outdated, packs: [:]) == nil)
    }

    @Test func nothingWhenTheInstalledRegionIsPartial() throws {
        let base = try catalog()
        let pack = try installedPack("veneto", in: base)
        let data = try Fixtures.manifestData()
        let manifest = try Manifest.decode(data, manifestHost: "github.com")
        let wider = CatalogBuilder.build(
            manifest: manifest, fetchedAt: Date(timeIntervalSince1970: 0), layers: [.trails, .places],
            installed: [.region("test"): pack])
        guard case .partiallyInstalled = wider.pack(.region("test"))!.status else {
            Issue.record("expected partiallyInstalled")
            return
        }
        #expect(RegionOffer.region(at: nevegal, catalog: wider, packs: [:]) == nil)
    }

    @Test(arguments: [PackState.queued, .verifying, .downloading(DownloadProgress(bytesReceived: 1, totalBytes: 2))])
    func aRegionInFlightFallsToTheNextSmallest(state: PackState) throws {
        let offer = RegionOffer.region(at: padova, catalog: try catalog(), packs: [.region("veneto"): state])
        #expect(offer?.id == .region("triveneto"))
    }

    /// Right after an install the packs say installed while the catalog, rebuilt a moment later, still says not.
    @Test func aRegionThePacksShowInstalledIsNotOfferedBeforeTheCatalogCatchesUp() throws {
        let stale = try catalog()
        #expect(status(stale, "veneto") == .notInstalled)
        let pack = try installedPack("veneto", in: stale)
        #expect(RegionOffer.region(at: padova, catalog: stale, packs: [.region("veneto"): .installed(pack)]) == nil)
        #expect(RegionOffer.region(at: nevegal, catalog: stale, packs: [.region("triveneto"): .installed(pack)]) == nil)
    }

    @Test(arguments: [PackState.notInstalled, .failed(.invalidConfiguration("the install failed"))])
    func aFailedOrNotInstalledStateStillOffers(state: PackState) throws {
        let offer = RegionOffer.region(at: padova, catalog: try catalog(), packs: [.region("veneto"): state])
        #expect(offer?.id == .region("veneto"))
    }

    @Test func nothingWithoutACatalog() {
        #expect(RegionOffer.region(at: padova, catalog: nil, packs: [:]) == nil)
    }

    @Test func nothingForAnInvalidCentre() throws {
        let catalog = try catalog()
        for centre in [
            CLLocationCoordinate2D(latitude: .nan, longitude: 11.9),
            CLLocationCoordinate2D(latitude: 45.4, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 95, longitude: 11.9),
        ] {
            #expect(RegionOffer.region(at: centre, catalog: catalog, packs: [:]) == nil)
        }
    }
}
