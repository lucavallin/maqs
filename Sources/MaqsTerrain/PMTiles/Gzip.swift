import Compression
import Foundation

/// CRC-32 (IEEE 802.3, reflected), the checksum in a gzip trailer.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}

/// Gzip (RFC 1952) decoding. Compression's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), so the member's header and
/// trailer are parsed here. The bytes are untrusted.
enum Gzip {
    private static let fhcrc: UInt8 = 0x02
    private static let fextra: UInt8 = 0x04
    private static let fname: UInt8 = 0x08
    private static let fcomment: UInt8 = 0x10
    private static let reservedFlags: UInt8 = 0xE0
    private static let chunkSize = 64 * 1024

    /// One RFC 1952 member; bytes after its trailer are ignored, as zlib does for the pipeline.
    ///
    /// Output past `limit` bytes is `sectionTooLarge`; the CRC-32 and length in the trailer are verified.
    static func inflate(_ data: Data, limit: Int) throws(PMTilesError) -> Data {
        let bytes = data.startIndex == 0 ? data : Data(data)
        let bodyStart = try headerLength(of: bytes)
        var output = Data()
        // The Xcode 26 SDK declares Data.withUnsafeBytes with an untyped rethrows, which would turn a typed
        // closure's error into `any Error`; the closure catches it instead.
        var failure: PMTilesError?
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            do throws(PMTilesError) {
                try inflateBody(raw, from: bodyStart, limit: limit, into: &output)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        // Compression does not report where the DEFLATE stream ended, so the trailer is the first place after the
        // header that holds this output's CRC-32 and length. Both must match, so a damaged stream or trailer is
        // rejected, and bytes after the member are ignored.
        let expectedCRC = CRC32.checksum(output)
        let expectedLength = UInt32(truncatingIfNeeded: output.count)
        var position = bodyStart
        while position + 8 <= bytes.count {
            if littleEndian32(bytes, at: position) == expectedCRC, littleEndian32(bytes, at: position + 4) == expectedLength {
                return output
            }
            position += 1
        }
        throw .corruptCompressedData("gzip trailer is missing or does not match the data")
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
    }

    /// The size of the member's header, with every field validated.
    private static func headerLength(of data: Data) throws(PMTilesError) -> Int {
        guard data.count >= 10 else { throw .corruptCompressedData("gzip header is truncated") }
        guard data[0] == 0x1F, data[1] == 0x8B else { throw .corruptCompressedData("not a gzip stream") }
        guard data[2] == 8 else { throw .corruptCompressedData("gzip method is not deflate") }
        let flags = data[3]
        guard flags & reservedFlags == 0 else { throw .corruptCompressedData("gzip reserved flags are set") }
        var position = 10
        if flags & fextra != 0 {
            guard data.count - position >= 2 else { throw .corruptCompressedData("gzip header is truncated") }
            let extraLength = Int(data[position]) | Int(data[position + 1]) << 8
            position += 2
            guard data.count - position >= extraLength else { throw .corruptCompressedData("gzip header is truncated") }
            position += extraLength
        }
        for flag in [fname, fcomment] where flags & flag != 0 {
            guard let end = data[position...].firstIndex(of: 0) else {
                throw .corruptCompressedData("gzip header is truncated")
            }
            position = end + 1
        }
        if flags & fhcrc != 0 {
            guard data.count - position >= 2 else { throw .corruptCompressedData("gzip header is truncated") }
            let stored = UInt32(data[position]) | UInt32(data[position + 1]) << 8
            guard CRC32.checksum(data.prefix(position)) & 0xFFFF == stored else {
                throw .corruptCompressedData("gzip header checksum mismatch")
            }
            position += 2
        }
        return position
    }

    /// Inflates the DEFLATE stream starting at `start` into `output`.
    private static func inflateBody(_ input: UnsafeRawBufferPointer, from start: Int, limit: Int,
                                    into output: inout Data) throws(PMTilesError) {
        let remaining = input.count - start
        guard remaining > 0, let base = input.baseAddress else { throw .corruptCompressedData("gzip body is truncated") }
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: placeholder, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .corruptCompressedData("the decompressor could not start")
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = base.assumingMemoryBound(to: UInt8.self) + start
        stream.src_size = remaining
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        while true {
            let produced: Int
            stream.dst_ptr = chunk
            stream.dst_size = chunkSize
            let status = compression_stream_process(&stream, 0)
            produced = chunkSize - stream.dst_size
            guard output.count + produced <= limit else { throw .sectionTooLarge }
            output.append(chunk, count: produced)
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // All input used and nothing more to drain: the stream ended early.
                if stream.src_size == 0 && produced < chunkSize { throw .corruptCompressedData("gzip body is truncated") }
            default:
                throw .corruptCompressedData("gzip body is not valid deflate data")
            }
        }
    }
}
