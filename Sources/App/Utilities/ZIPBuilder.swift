import Foundation

/// Builds ZIP archives in memory using the STORE method (no compression).
/// Ideal for already-compressed data like JPEG/PNG images.
struct ZIPBuilder {

    struct Entry {
        let path: String
        let data: Data
    }

    /// Assembles a valid ZIP archive from the given entries.
    static func build(entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var localOffsets: [UInt32] = []

        for entry in entries {
            let sanitized = sanitizeFilename(entry.path)
            let nameData = Data(sanitized.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)
            localOffsets.append(offset)

            // Local file header
            archive.appendUInt32(0x04034B50)       // signature
            archive.appendUInt16(20)                // version needed (2.0)
            archive.appendUInt16(0)                 // flags
            archive.appendUInt16(0)                 // compression: STORE
            archive.appendUInt16(0)                 // mod time
            archive.appendUInt16(0)                 // mod date
            archive.appendUInt32(crc)               // crc-32
            archive.appendUInt32(size)              // compressed size
            archive.appendUInt32(size)              // uncompressed size
            archive.appendUInt16(UInt16(nameData.count)) // name length
            archive.appendUInt16(0)                 // extra field length
            archive.append(nameData)
            archive.append(entry.data)

            // Central directory entry
            centralDirectory.appendUInt32(0x02014B50) // signature
            centralDirectory.appendUInt16(20)         // version made by
            centralDirectory.appendUInt16(20)         // version needed
            centralDirectory.appendUInt16(0)          // flags
            centralDirectory.appendUInt16(0)          // compression: STORE
            centralDirectory.appendUInt16(0)          // mod time
            centralDirectory.appendUInt16(0)          // mod date
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(size)       // compressed size
            centralDirectory.appendUInt32(size)       // uncompressed size
            centralDirectory.appendUInt16(UInt16(nameData.count))
            centralDirectory.appendUInt16(0)          // extra field length
            centralDirectory.appendUInt16(0)          // comment length
            centralDirectory.appendUInt16(0)          // disk number start
            centralDirectory.appendUInt16(0)          // internal attributes
            centralDirectory.appendUInt32(0)          // external attributes
            centralDirectory.appendUInt32(offset)     // local header offset
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        // End of central directory record
        archive.appendUInt32(0x06054B50)           // signature
        archive.appendUInt16(0)                     // disk number
        archive.appendUInt16(0)                     // disk with CD
        archive.appendUInt16(UInt16(entries.count)) // entries on disk
        archive.appendUInt16(UInt16(entries.count)) // total entries
        archive.appendUInt32(cdSize)                // CD size
        archive.appendUInt32(cdOffset)              // CD offset
        archive.appendUInt16(0)                     // comment length

        return archive
    }

    /// Standard CRC-32 with precomputed lookup table.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ Self.crcTable[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Strips characters unsafe for ZIP paths.
    static func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "\\:*?\"<>|")
        var sanitized = name.unicodeScalars.filter { !unsafe.contains($0) }
            .map { Character($0) }
            .map { String($0) }
            .joined()
        // Collapse multiple slashes
        while sanitized.contains("//") {
            sanitized = sanitized.replacingOccurrences(of: "//", with: "/")
        }
        // Remove leading slash
        if sanitized.hasPrefix("/") {
            sanitized = String(sanitized.dropFirst())
        }
        return sanitized.isEmpty ? "file" : sanitized
    }

    // MARK: - CRC-32 Lookup Table

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}
