import Foundation

/// Derives a ``Catalog`` from a manifest, the configured layers and the installed packs.
enum CatalogBuilder {
    /// The per-layer selection for one pack, over the configured layers the pack offers. `nil` if the pack is not listed.
    static func selections(manifest: Manifest, pack: PackID, layers: Set<Layer>) -> [Layer: ReadableVersions.Selection]? {
        let entries: (Layer) -> [ManifestEntry]?
        switch pack {
        case .region(let id):
            guard let region = manifest.regions.first(where: { $0.id == id }) else { return nil }
            entries = region.entries(for:)
        case .base(let id):
            guard let base = manifest.base.first(where: { $0.id == id }) else { return nil }
            entries = base.entries(for:)
        }
        var result: [Layer: ReadableVersions.Selection] = [:]
        for layer in layers {
            if let offered = entries(layer), let selection = ReadableVersions.select(offered, for: layer) {
                result[layer] = selection
            }
        }
        return result
    }

    static func build(manifest: Manifest, fetchedAt: Date, layers: Set<Layer>, installed: [PackID: InstalledPack]) -> Catalog {
        let attribution = manifest.attribution.map {
            Attribution(text: $0.text, licence: $0.licence, url: $0.url, layers: $0.layers.compactMap(Layer.init(rawValue:)))
        }
        let regions = manifest.regions.map { region in
            summary(.region(region.id), names: region.name, bbox: BoundingBox(region.bbox), manifest: manifest, layers: layers, installed: installed)
        }
        let basePacks = manifest.base.compactMap { base -> PackSummary? in
            let summary = summary(.base(base.id), names: [:], bbox: nil, manifest: manifest, layers: layers, installed: installed)
            return summary.layers.isEmpty ? nil : summary
        }
        return Catalog(release: manifest.release, createdAt: manifest.createdAt, fetchedAt: fetchedAt,
                       attribution: attribution, regions: regions, basePacks: basePacks)
    }

    private static func summary(_ id: PackID, names: [String: String], bbox: BoundingBox?, manifest: Manifest,
                                layers: Set<Layer>, installed: [PackID: InstalledPack]) -> PackSummary {
        let selections = selections(manifest: manifest, pack: id, layers: layers) ?? [:]
        var availability: [Layer: LayerAvailability] = [:]
        var total: Int64 = 0
        for (layer, selection) in selections {
            switch selection {
            case .readable(let version, let files):
                guard let main = files.first(where: { $0.role == nil }) ?? files.first else { continue }
                let bytes = files.reduce(0) { $0 + $1.bytes }
                total += bytes
                availability[layer] = .available(bytes: bytes, schemaVersion: version, dataDate: main.dataDate, osmTimestamp: main.osmTimestamp)
            case .unreadable(let offered):
                availability[layer] = .unreadable(offeredVersions: offered)
            }
        }
        let status = status(selections: selections, release: manifest.release, installed: installed[id])
        return PackSummary(id: id, names: names, bbox: bbox, layers: availability, totalBytes: total, status: status)
    }

    /// `installed` when every readable configured layer matches by SHA-256; `updateAvailable` when any differs
    /// (bytes = changed + missing layers); `partiallyInstalled` when layers are only missing. Bundled packs are
    /// always `installed`: the app owns that file.
    static func status(selections: [Layer: ReadableVersions.Selection], release: String, installed: InstalledPack?) -> PackStatus {
        guard let installed else { return .notInstalled }
        if installed.bundled { return .installed(release: installed.release) }
        var changed: Int64 = 0
        var missing: Set<Layer> = []
        var missingBytes: Int64 = 0
        for (layer, selection) in selections {
            guard case .readable(_, let files) = selection else { continue }
            let bytes = files.reduce(0) { $0 + $1.bytes }
            guard let local = installed.files[layer], !local.isEmpty else {
                missing.insert(layer); missingBytes += bytes; continue
            }
            if Set(local.compactMap(\.sha256)) != Set(files.map(\.sha256)) { changed += bytes }
        }
        if changed > 0 { return .updateAvailable(release: release, bytes: changed + missingBytes) }
        if !missing.isEmpty { return .partiallyInstalled(missing: missing) }
        return .installed(release: installed.release)
    }
}
