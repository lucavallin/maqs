import CryptoKit
import Foundation

/// Lowercase hex SHA-256 for tests that compare against manifest digests.
public enum SHA256Hex {
    /// The lowercase hex SHA-256 digest of `data`.
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
