import Foundation

/// Why a PMTiles file could not be read. A file that throws any of these is damaged, truncated or not a PMTiles archive.
public enum PMTilesError: Error, Equatable, LocalizedError {
    /// The file does not start with the PMTiles magic bytes.
    case notPMTiles
    /// The archive's version is not 3; the payload is the version found.
    case unsupportedVersion(UInt8)
    /// A compression this reader does not decode; the payload is the PMTiles compression code.
    case unsupportedCompression(UInt8)
    /// The file ends before a section it declares.
    case truncated
    /// A directory is malformed; the payload says how, never what it contained.
    case corruptDirectory(String)
    /// A gzip stream is malformed; the payload says how.
    case corruptCompressedData(String)
    /// A section declares a size above this reader's cap.
    case sectionTooLarge
    /// A leaf directory points at another leaf directory, which this reader does not follow.
    case nestedLeafDirectory
    /// The file cannot be opened or read.
    case unreadableFile

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .notPMTiles:
            "This file is not a map archive. Remove the region and install it again."
        case .unsupportedVersion(let version):
            "This map file uses format version \(version), which this app cannot read. Update the app."
        case .unsupportedCompression(let code):
            "This map file uses a compression (code \(code)) this app cannot read. Update the app."
        case .truncated:
            "This map file is incomplete. Remove the region and install it again."
        case .corruptDirectory, .corruptCompressedData, .nestedLeafDirectory:
            "This map file is damaged. Remove the region and install it again."
        case .sectionTooLarge:
            "This map file declares a section larger than this app accepts. Remove the region and install it again."
        case .unreadableFile:
            "This map file cannot be read. Check that the region is still installed, or install it again."
        }
    }
}
