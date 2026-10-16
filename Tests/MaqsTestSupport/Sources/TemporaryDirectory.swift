import Foundation

/// A fresh directory per test, deleted on `deinit`.
public final class TemporaryDirectory: Sendable {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "maqs-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
