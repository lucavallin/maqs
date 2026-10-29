#if canImport(UIKit)
import CryptoKit
import Foundation
import UIKit

/// The content digest of each picture an app hands the map as marker content, one per `UIImage` instance.
///
/// A digest encodes the picture as PNG and hashes it, which costs milliseconds per picture, and the map names its
/// markers again on every change of `markers` and of the selection. So each instance is encoded once and its digest
/// kept for as long as the instance lives: the table holds its pictures weakly and compares them by identity.
/// A picture with no PNG data gets a token of its own instead, so two such pictures never share a name.
@MainActor final class ImageDigests {
    /// The table the map uses.
    static let shared = ImageDigests()

    private let digests = NSMapTable<UIImage, NSString>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private let encode: (UIImage) -> Data?

    /// `encode` turns a picture into the bytes its digest hashes; tests count its calls.
    init(encode: @escaping (UIImage) -> Data? = { $0.pngData() }) {
        self.encode = encode
    }

    /// The hex SHA-256 prefix of the picture's PNG data, or `unencodable-<UUID>` for a picture with none.
    func digest(of image: UIImage) -> String {
        if let known = digests.object(forKey: image) { return known as String }
        let digest = if let data = encode(image) {
            SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        } else {
            "unencodable-" + UUID().uuidString
        }
        digests.setObject(digest as NSString, forKey: image)
        return digest
    }
}
#endif
