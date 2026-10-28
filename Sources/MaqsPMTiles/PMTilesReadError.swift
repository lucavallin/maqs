import Foundation

/// Why a PMTiles file could not be read. `MaqsTerrain` maps each case to its public `PMTilesError` of the same name, so
/// callers outside the package never see this type. A file that throws any of these is damaged, truncated or not a
/// PMTiles archive.
package enum PMTilesReadError: Error, Equatable {
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
}
