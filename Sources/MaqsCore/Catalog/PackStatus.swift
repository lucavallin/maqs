/// How an installed pack compares with the latest release.
public enum PackStatus: Sendable, Equatable {
    /// Nothing is installed for the pack.
    case notInstalled
    /// Every configured layer is installed and matches the release.
    case installed(release: String)
    /// At least one installed layer's files differ from the release; `bytes` is the download an update needs.
    ///
    /// An update can be offered while a layer of the pack is available only in a version this package cannot read;
    /// ``Maqs/install(_:)`` then throws ``DownloadError/layerUnreadable(_:)`` for that layer. Check
    /// ``PackSummary/layers`` for a ``LayerAvailability/unreadable(offeredVersions:)`` entry before offering it.
    case updateAvailable(release: String, bytes: Int64)
    /// Installed, but configured layers the release offers are missing (the app's layer set grew).
    case partiallyInstalled(missing: Set<Layer>)
}
