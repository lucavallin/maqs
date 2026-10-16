import Foundation
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct CatalogTests {
    let manifest: Manifest
    let fetchedAt = Date(timeIntervalSince1970: 1_000)

    init() throws {
        manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "github.com")
    }

    func build(layers: Set<Layer>, installed: [PackID: InstalledPack] = [:], manifest: Manifest? = nil) -> Catalog {
        CatalogBuilder.build(manifest: manifest ?? self.manifest, fetchedAt: fetchedAt, layers: layers, installed: installed)
    }

    /// An installed pack whose files match the fixture manifest's entries for `layers`, with optional overrides.
    func installedFromManifest(_ id: PackID, layers: Set<Layer>, release: String = "data-ci",
                               shaOverride: [Layer: String] = [:]) -> InstalledPack {
        let selections = CatalogBuilder.selections(manifest: manifest, pack: id, layers: layers)!
        var files: [Layer: [InstalledFile]] = [:]
        for (layer, selection) in selections {
            guard case .readable(let version, let entries) = selection else { continue }
            files[layer] = entries.map {
                InstalledFile(url: URL(filePath: "/x/\($0.file)"), role: $0.role, schemaVersion: version,
                              sha256: shaOverride[layer] ?? $0.sha256, bytes: $0.bytes, dataDate: $0.dataDate)
            }
        }
        return InstalledPack(id: id, release: release, files: files, bundled: false)
    }

    @Test("only configured layers appear, with bytes, version and dates")
    func configuredLayers() throws {
        let catalog = build(layers: [.trails, .places])
        #expect(catalog.release == "data-ci")
        #expect(catalog.fetchedAt == fetchedAt)
        let test = try #require(catalog.pack(.region("test")))
        #expect(Set(test.layers.keys) == [.trails, .places])
        guard case .available(let bytes, let version, _, let osm)? = test.layers[.trails] else { Issue.record("trails"); return }
        #expect(version == 1)
        #expect(osm != nil)
        let trailsEntries = manifest.regions[0].entries(for: .trails)!
        #expect(bytes == trailsEntries.reduce(0) { $0 + $1.bytes })
        #expect(test.totalBytes == test.layers.values.reduce(0) { sum, a in
            if case .available(let b, _, _, _) = a { return sum + b } else { return sum } })
        #expect(test.status == .notInstalled)
    }

    @Test("names keep every language key and the bbox is the manifest's")
    func names() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var name = regions[0]["name"] as! [String: String]
            name["de"] = "Nevegal (Test)"
            regions[0]["name"] = name
            object["regions"] = regions
        }
        let catalog = build(layers: [.trails], manifest: try Manifest.decode(data, manifestHost: "github.com"))
        let test = try #require(catalog.pack(.region("test")))
        #expect(test.names["de"] == "Nevegal (Test)")
        #expect(test.names["en"] == "Nevegal (test)")
        #expect(test.bbox == BoundingBox(minLon: 12.21, minLat: 46.08, maxLon: 12.29, maxLat: 46.13))
    }

    @Test("a layer the manifest does not offer is absent, not an error")
    func notOffered() throws {
        let catalog = build(layers: [.terrainHD, .trails])
        let test = try #require(catalog.pack(.region("test")))
        #expect(test.layers[.terrainHD] == nil)
        #expect(test.layers[.trails] != nil)
        #expect(test.status == .notInstalled)
    }

    @Test("an unreadable layer is reported with the versions offered")
    func unreadable() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["curvature"] = layers["curvature"]!.map { var e = $0; e["layer_schema_version"] = 2; return e }
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        let catalog = build(layers: [.curvature, .trails], manifest: try Manifest.decode(data, manifestHost: "github.com"))
        let test = try #require(catalog.pack(.region("test")))
        #expect(test.layers[.curvature] == .unreadable(offeredVersions: [2]))
        guard case .available = test.layers[.trails] else { Issue.record("trails should be available"); return }
    }

    @Test("installed, updateAvailable and partiallyInstalled follow the installed files")
    func statuses() throws {
        let id = PackID.region("test")
        let same = installedFromManifest(id, layers: [.trails, .places])
        #expect(build(layers: [.trails, .places], installed: [id: same]).pack(id)?.status == .installed(release: "data-ci"))

        let changed = installedFromManifest(id, layers: [.trails, .places], shaOverride: [.places: String(repeating: "0", count: 64)])
        let placesBytes = manifest.regions[0].entries(for: .places)!.reduce(0) { $0 + $1.bytes }
        #expect(build(layers: [.trails, .places], installed: [id: changed]).pack(id)?.status
                == .updateAvailable(release: "data-ci", bytes: placesBytes))

        let partial = installedFromManifest(id, layers: [.trails])
        #expect(build(layers: [.trails, .places], installed: [id: partial]).pack(id)?.status == .partiallyInstalled(missing: [.places]))

        let both = installedFromManifest(id, layers: [.trails], shaOverride: [.trails: String(repeating: "0", count: 64)])
        let trailsBytes = manifest.regions[0].entries(for: .trails)!.reduce(0) { $0 + $1.bytes }
        #expect(build(layers: [.trails, .places], installed: [id: both]).pack(id)?.status
                == .updateAvailable(release: "data-ci", bytes: trailsBytes + placesBytes))
    }

    @Test("a bundled pack is installed and never updatable")
    func bundled() throws {
        let id = PackID.base("triveneto")
        let bundled = InstalledPack(id: id, release: "bundled", files: [.basemap: [
            InstalledFile(url: URL(filePath: "/app/base.pmtiles"), role: nil, schemaVersion: 1, sha256: nil, bytes: 1, dataDate: nil)]], bundled: true)
        let catalog = build(layers: [.basemap], installed: [id: bundled])
        #expect(catalog.pack(id)?.status == .installed(release: "bundled"))
    }

    @Test("base packs are listed without names or bbox, and omitted when basemap is not configured")
    func basePacks() throws {
        let with = build(layers: [.basemap])
        let base = try #require(with.basePacks.first)
        #expect(base.id == .base("triveneto"))
        #expect(base.names.isEmpty && base.bbox == nil)
        #expect(Set(base.layers.keys) == [.basemap])
        #expect(build(layers: [.trails]).basePacks.isEmpty)
    }

    @Test("attribution maps known layer names and drops unknown ones")
    func attribution() throws {
        let data = try Fixtures.manifestJSON { object in
            var attribution = object["attribution"] as! [[String: Any]]
            attribution[0]["layers"] = ["basemap", "roads"]
            object["attribution"] = attribution
        }
        let catalog = build(layers: [.basemap], manifest: try Manifest.decode(data, manifestHost: "github.com"))
        #expect(catalog.attribution[0].layers == [.basemap])
        #expect(catalog.attribution.count == manifest.attribution.count)
    }

    @Test("a bounding box contains its interior and rejects the outside")
    func bbox() {
        let box = BoundingBox(minLon: 12.21, minLat: 46.08, maxLon: 12.29, maxLat: 46.13)
        #expect(box.contains(longitude: 12.25, latitude: 46.10))
        #expect(!box.contains(longitude: 12.30, latitude: 46.10))
        #expect(BoundingBox([1, 2, 3]) == nil)
    }

    @Test("an inverted bounding box contains nothing and does not trap")
    func invertedBox() {
        let box = BoundingBox(minLon: 12.29, minLat: 46.13, maxLon: 12.21, maxLat: 46.08)
        #expect(!box.contains(longitude: 12.25, latitude: 46.10))
    }
}
