import Foundation

/// Every error `MaqsCore` throws, by subsystem.
public enum MaqsError: Error, LocalizedError, Sendable, Equatable {
    /// The manifest was not accepted.
    case manifest(ManifestError)
    /// A download or install failed.
    case download(DownloadError)
    /// The storage directory has a problem.
    case storage(StorageError)
    /// `sources.json` was not accepted.
    case sources(SourcesError)

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .manifest(let e): e.errorDescription
        case .download(let e): e.errorDescription
        case .storage(let e): e.errorDescription
        case .sources(let e): e.errorDescription
        }
    }
}

/// Why a manifest was not accepted. The previous cached manifest stays in use.
public enum ManifestError: Error, LocalizedError, Sendable, Equatable {
    /// `manifest_version` is one this package does not read.
    case unsupportedVersion(Int)
    /// The JSON does not match the format; the message names the field, never the content.
    case invalid(String)
    /// An entry URL is not `https`; the payload is the field path, never the URL.
    case insecureURL(String)
    /// An entry URL has another host than the manifest URL, or carries credentials or a port; the payload is the field path.
    case foreignHost(String)
    /// The fetch failed; the status code when there was a response.
    case network(statusCode: Int?)
    /// The server answered 429.
    case rateLimited

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "This data release (manifest version \(v)) needs a newer app. Update the app."
        case .invalid(let what): "The map data index could not be read (\(what)). Try again later."
        case .insecureURL(let path): "The map data index points at a non-HTTPS address at \(path) and was rejected."
        case .foreignHost(let path): "The map data index points outside its own host at \(path) and was rejected."
        case .network(let code): "The map data index could not be fetched\(code.map { " (HTTP \($0))" } ?? ""). Check the connection and try again."
        case .rateLimited: "Too many requests to the data host. Try again in a few minutes."
        }
    }
}

/// Why a pack was not installed. Nothing already installed changes.
public enum DownloadError: Error, LocalizedError, Sendable, Equatable {
    /// The SHA-256 of the file differs from the manifest; it was discarded.
    case checksumMismatch(file: String)
    /// The size of the file differs from the manifest; it was discarded.
    case sizeMismatch(file: String)
    /// The transfer failed; the status code when there was a response.
    case network(statusCode: Int?)
    /// The caller cancelled the download.
    case cancelled
    /// Every version of this layer is newer than the package reads.
    case layerUnreadable(Layer)
    /// The catalog does not list this pack; refresh the catalog.
    case notInCatalog(PackID)
    /// `install` was called before any catalog was loaded.
    case noCatalog

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let f): "\(f) did not match its checksum and was discarded. Try the download again."
        case .sizeMismatch(let f): "\(f) had an unexpected size and was discarded. Try the download again."
        case .network(let code): "The download failed\(code.map { " (HTTP \($0))" } ?? ""). Check the connection and try again."
        case .cancelled: "The download was cancelled."
        case .layerUnreadable(let layer): "The \(layer.rawValue) layer needs a newer app. Update the app."
        case .notInCatalog(let id): "\(id) is not in the current catalog. Refresh and try again."
        case .noCatalog: "Load the catalog before installing."
        }
    }
}

/// A problem with the storage directory.
public enum StorageError: Error, LocalizedError, Sendable, Equatable {
    /// The storage directory could not be created.
    case cannotCreateDirectory(String)
    /// A file could not be written.
    case writeFailed(String)
    /// `pack.json` is unreadable; the pack reads as not installed until reinstalled.
    case corruptRecord(PackID)

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let p): "Could not create the map storage folder (\(p)). Free disk space or check permissions."
        case .writeFailed(let p): "Could not write \(p). Free disk space and try again."
        case .corruptRecord(let id): "The record of \(id) is unreadable. Reinstall the pack."
        }
    }
}

/// Why `sources.json` was not accepted. The last good copy stays in use.
public enum SourcesError: Error, LocalizedError, Sendable, Equatable {
    /// `sources_version` is one this package does not read.
    case unsupportedVersion(Int)
    /// The JSON does not match the format; the message names the field, never the content.
    case invalid(String)
    /// The fetch failed; the status code when there was a response.
    case network(statusCode: Int?)

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "The online sources file (version \(v)) needs a newer app. Update the app."
        case .invalid(let what): "The online sources file could not be read (\(what))."
        case .network(let code): "The online sources file could not be fetched\(code.map { " (HTTP \($0))" } ?? "")."
        }
    }
}
