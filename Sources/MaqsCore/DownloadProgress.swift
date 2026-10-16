/// Bytes received so far and the total expected, summed over every file of a pack.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes the pack's current transfers have received so far.
    public let bytesReceived: Int64
    /// Bytes expected in total, as the manifest lists them; 0 when unknown.
    public let totalBytes: Int64

    /// Creates a progress value; `fraction` stays within 0…1 whatever the two numbers are.
    public init(bytesReceived: Int64, totalBytes: Int64) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    /// 0…1, or 0 when the total is unknown.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
    }
}
