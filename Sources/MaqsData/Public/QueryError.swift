import Foundation
import SQLite3

/// Why a reader could not open its files or answer a query.
///
/// A file is always named by its last path component, never its full path, which holds the app's container.
public enum QueryError: Error, Equatable, LocalizedError {
    /// SQLite could not open the file: it is missing, or the URL is not a local file.
    case cannotOpen(file: String)
    /// The file holds another layer than the reader's (a places file passed to the trails reader).
    case wrongLayer(file: String, expected: String, found: String)
    /// The file's `schema_version` is one this version of the package does not read.
    case unsupportedSchemaVersion(file: String, version: Int)
    /// A table or column this package reads is missing; `missing` names it (`metadata`, `trails_rtree`, `trails.ref_rei`).
    case incompatibleFile(file: String, missing: String)
    /// Two files of one reader hold the same region.
    case duplicateRegion(String)
    /// The file is damaged: it is not SQLite, it is truncated, or a value in it cannot be decoded. `detail` says what
    /// failed, never the SQL text.
    case corruptData(file: String, detail: String)
    /// The file could not be read: an I/O or permission failure. On iOS that includes a file under Complete data
    /// protection while the device is locked, and on Apple platforms a file removed or replaced since it was opened
    /// (a region update or removal), which the system SQLite stops reading.
    case unreadable(file: String)
    /// A query argument is out of range or not a usable number; the payload says which.
    case invalidInput(String)
    /// The road segment (an OSM way id) is in none of the open curvature files.
    case unknownSegment(Int64)

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let file):
            "\(file) could not be opened. Check that the region is installed, and install it again if it is."
        case .wrongLayer(let file, let expected, let found):
            "\(file) holds \(found) data, not \(expected). Pass each reader only the files of its own layer."
        case .unsupportedSchemaVersion(let file, let version):
            "\(file) uses data format version \(version), which this app cannot read. Update the app, or install the region again."
        case .incompatibleFile(let file, let missing):
            "\(file) lacks \(missing), which this app reads. Install the region again from the current data release."
        case .duplicateRegion(let region):
            "Two files hold the region \(region). Pass each region's file once."
        case .corruptData(let file, let detail):
            "\(file) is damaged (\(detail)). Remove the region and install it again."
        case .unreadable(let file):
            "\(file) could not be read. If the region was updated or removed since it was opened, pass the current files again. On iOS a file under Complete data protection cannot be read while the device is locked; try again after unlocking. Reinstall the region if it keeps failing."
        case .invalidInput(let detail):
            "The query was rejected (\(detail)). Adjust the input and try again."
        case .unknownSegment(let id):
            "Road segment \(id) is in none of the installed regions. Look up the road again near the current position."
        }
    }

    /// The error for a failed SQLite call on `file`.
    ///
    /// An I/O, permission or cannot-open failure (`SQLITE_IOERR` with any extended code, `SQLITE_PERM`,
    /// `SQLITE_CANTOPEN`) is ``unreadable(file:)``. That includes `SQLITE_IOERR_VNODE`, Apple's code for a file unlinked
    /// or renamed while open. A short read is ``corruptData(file:detail:)``, because the file is shorter than its
    /// contents claim, and so is every other code.
    static func sqlite(_ code: Int32, file: String) -> QueryError {
        let shortRead = SQLITE_IOERR | (2 << 8)
        guard code != shortRead else { return .corruptData(file: file, detail: "SQLite result code \(code)") }
        switch code & 0xFF {
        case SQLITE_IOERR, SQLITE_PERM, SQLITE_CANTOPEN:
            return .unreadable(file: file)
        default:
            return .corruptData(file: file, detail: "SQLite result code \(code)")
        }
    }
}
