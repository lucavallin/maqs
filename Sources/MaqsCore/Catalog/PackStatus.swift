/// How an installed pack compares with the latest release.
public enum PackStatus: Sendable, Equatable {
    /// Nothing is installed for the pack.
    case notInstalled
    /// Every configured layer is installed and matches the release.
    case installed(release: String)
    /// At least one installed layer's files differ from the release; `bytes` is the download an update needs.
    case updateAvailable(release: String, bytes: Int64)
    /// Installed, but configured layers the release offers are missing (the app's layer set grew).
    case partiallyInstalled(missing: Set<Layer>)
}
