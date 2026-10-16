import Foundation

/// Every path under the storage root. Nothing else in the package builds a path.
///
/// ```
/// <root>/manifest.json, manifest.meta.json, sources.json, sources.meta.json
/// <root>/packs/<region-id | base-id>/pack.json
/// <root>/packs/<…>/<layer>/<sha256>/<file>
/// <root>/downloads/<file>, <file>.resume
/// ```
///
/// Installed files sit under their SHA-256, so an update never overwrites a file the live `pack.json` names.
struct StorageLayout: Sendable {
    let root: URL

    var manifest: CachedDocument {
        CachedDocument(dataURL: root.appending(path: "manifest.json"), metaURL: root.appending(path: "manifest.meta.json"))
    }
    var sources: CachedDocument {
        CachedDocument(dataURL: root.appending(path: "sources.json"), metaURL: root.appending(path: "sources.meta.json"))
    }
    var packsDirectory: URL { root.appending(path: "packs", directoryHint: .isDirectory) }
    var downloadsDirectory: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }

    func packDirectory(_ id: PackID) -> URL { packsDirectory.appending(path: id.directoryName, directoryHint: .isDirectory) }
    func recordURL(_ id: PackID) -> URL { packDirectory(id).appending(path: "pack.json") }
    func layerDirectory(_ id: PackID, layer: Layer) -> URL { packDirectory(id).appending(path: layer.rawValue, directoryHint: .isDirectory) }
    func fileURL(_ id: PackID, layer: Layer, sha256: String, fileName: String) -> URL {
        layerDirectory(id, layer: layer).appending(path: sha256, directoryHint: .isDirectory).appending(path: fileName)
    }
    func downloadURL(fileName: String) -> URL { downloadsDirectory.appending(path: fileName) }
    func resumeDataURL(fileName: String) -> URL { downloadsDirectory.appending(path: fileName + ".resume") }

    /// `Application Support/Maqs` in the app's container.
    static func defaultRoot() throws -> URL {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return support.appending(path: "Maqs", directoryHint: .isDirectory)
        } catch {
            throw StorageError.cannotCreateDirectory("Application Support")
        }
    }
}
