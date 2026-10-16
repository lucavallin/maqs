import Foundation

/// A fetched document and its fetch metadata, written atomically. `read()` is `nil` unless both halves exist.
struct CachedDocument: Sendable {
    struct Meta: Codable, Sendable, Equatable {
        var etag: String?
        var fetchedAt: Date
    }

    let dataURL: URL
    let metaURL: URL

    func read() -> (data: Data, meta: Meta)? {
        guard let data = try? Data(contentsOf: dataURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData)
        else { return nil }
        return (data, meta)
    }

    func write(data: Data, meta: Meta) throws {
        do {
            try data.write(to: dataURL, options: .atomic)
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(dataURL.lastPathComponent)
        }
    }

    func touch(fetchedAt: Date) throws {
        guard let current = read() else { return }
        var meta = current.meta
        meta.fetchedAt = fetchedAt
        do {
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(metaURL.lastPathComponent)
        }
    }
}
