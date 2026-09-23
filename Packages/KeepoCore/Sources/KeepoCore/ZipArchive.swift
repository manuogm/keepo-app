import Foundation

/// A zip archive of **stored** (uncompressed) entries — the container an
/// `.xlsx` file is, and the only thing this project needs one for.
///
/// Hand-written rather than a dependency: stored entries are ~80 lines of
/// header arithmetic, every reader must support them, and the files are a few
/// hundred kilobytes of text at the very most. Compression would save bytes
/// nobody is short of, at the cost of a library in the money app's supply
/// chain.
///
/// Limits, stated rather than checked: fewer than 65,535 entries and under
/// 4 GB in total (no Zip64), which an export of one person's transactions
/// cannot approach.
public enum ZipArchive {
    public struct Entry: Sendable {
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public static func stored(_ entries: [Entry]) -> Data {
        var archive = Data()
        var directory = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            // Local file header.
            archive.append(le32: 0x0403_4b50)
            archive.append(le16: 20)          // version needed: 2.0
            archive.append(le16: 0)           // flags
            archive.append(le16: 0)           // method: stored
            archive.append(le16: 0)           // mod time: 00:00
            archive.append(le16: dosEpochDate)
            archive.append(le32: crc)
            archive.append(le32: size)        // compressed = uncompressed when stored
            archive.append(le32: size)
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0)           // extra field length
            archive.append(name)
            archive.append(entry.data)

            // The matching central directory record.
            directory.append(le32: 0x0201_4b50)
            directory.append(le16: 20)        // version made by
            directory.append(le16: 20)        // version needed
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le16: dosEpochDate)
            directory.append(le32: crc)
            directory.append(le32: size)
            directory.append(le32: size)
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0)         // extra
            directory.append(le16: 0)         // comment
            directory.append(le16: 0)         // disk number start
            directory.append(le16: 0)         // internal attributes
            directory.append(le32: 0)         // external attributes
            directory.append(le32: offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(directory)

        // End of central directory.
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(directory.count))
        archive.append(le32: directoryOffset)
        archive.append(le16: 0)
        return archive
    }

    /// 1980-01-01, the first day a DOS timestamp can express. A fixed date
    /// keeps the archive byte-for-byte reproducible; the file's real creation
    /// time is the filesystem's to record, not the container's.
    private static let dosEpochDate: UInt16 = (0 << 9) | (1 << 5) | 1

    /// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) — the checksum
    /// every zip reader verifies.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
