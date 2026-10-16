/// Where a pack is in its install lifecycle, as SwiftUI observes it in ``MaqsState/packs``.
public enum PackState: Sendable, Equatable {
    /// Nothing is installed and no install is queued or running.
    case notInstalled
    /// An install is queued or downloading; the bytes are summed over the pack's files.
    case downloading(DownloadProgress)
    /// Every file is downloaded; sizes and SHA-256s are being checked.
    case verifying
    /// The pack's files are installed and ready to open.
    case installed(InstalledPack)
    /// The last install attempt failed; the previous files, if any, are still installed.
    case failed(MaqsError)
}
