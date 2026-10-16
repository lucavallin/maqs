import CryptoKit
import Foundation

/// Streaming SHA-256 of a file, 1 MiB at a time, so a 400 MB basemap never sits in memory.
enum FileHash {
    /// The lowercase hex SHA-256 digest of the file at `url`; throws when the file cannot be opened or read.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
