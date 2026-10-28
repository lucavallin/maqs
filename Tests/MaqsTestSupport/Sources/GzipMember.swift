import Compression
import Foundation
import MaqsPMTiles

/// Builds RFC 1952 gzip members with chosen header fields, for tests of `Gzip`.
public enum GzipMember {
    /// Raw DEFLATE of `payload` (what `COMPRESSION_ZLIB` encodes).
    public static func deflate(_ payload: Data) -> Data {
        guard !payload.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = payload.count * 2 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = payload.withUnsafeBytes { source in
            compression_encode_buffer(&out, capacity, source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return Data(out.prefix(written))
    }

    /// A whole gzip member around `payload`, with the optional header fields (extra, name, comment, header CRC) set as asked.
    public static func make(_ payload: Data, extra: Data? = nil, name: String? = nil, comment: String? = nil,
                     headerCRC: Bool = false) -> Data {
        var flags: UInt8 = 0
        if headerCRC { flags |= 0x02 }
        if extra != nil { flags |= 0x04 }
        if name != nil { flags |= 0x08 }
        if comment != nil { flags |= 0x10 }
        var header = Data([0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 0xFF])
        if let extra {
            header.append(contentsOf: [UInt8(extra.count & 0xFF), UInt8(extra.count >> 8)])
            header.append(extra)
        }
        if let name { header.append(Data(name.utf8)); header.append(0) }
        if let comment { header.append(Data(comment.utf8)); header.append(0) }
        if headerCRC {
            let crc = CRC32.checksum(header)
            header.append(contentsOf: [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)])
        }
        var member = header
        member.append(deflate(payload))
        for value in [CRC32.checksum(payload), UInt32(truncatingIfNeeded: payload.count)] {
            member.append(contentsOf: (0..<4).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) })
        }
        return member
    }
}
