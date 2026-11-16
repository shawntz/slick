import Compression
import Foundation

/// Builds ZIP archives in memory for tests, with knobs that make them lie. Its checksum and
/// compression are its own, so a mistake in the reader cannot hide behind the same mistake here.
struct ZipBuilder {
    struct File {
        var name: String
        var contents: Data
        /// 0 stores, 8 deflates; anything else is written as given, with the contents stored.
        var method: UInt16 = 8
        /// Replaces the size after inflation in both headers.
        var declaredSize: Int?
        var declaredChecksum: UInt32?
        /// The Unix mode in the high 16 bits, as zip tools write it: a regular file by default.
        var externalAttributes: UInt32 = 0o100644 << 16
        /// 3 is Unix.
        var host: UInt8 = 3
        var flags: UInt16 = 0
        /// A different name in the local header.
        var localName: String?
        /// A different method in the local header.
        var localMethod: UInt16?
        /// Bytes written as the compressed data, instead of the contents compressed.
        var rawData: Data?

        init(_ name: String, _ contents: Data, method: UInt16 = 8) {
            self.name = name
            self.contents = contents
            self.method = method
        }

        init(_ name: String, text: String, method: UInt16 = 8) {
            self.init(name, Data(text.utf8), method: method)
        }
    }

    var files: [File]
    var entryCount: Int?
    var directoryOffsetShift = 0
    var directorySizeShift = 0
    /// Added to each central entry's local header offset, by position.
    var headerOffsetShifts: [Int: Int] = [:]
    /// Added to each central entry's compressed size, by position.
    var compressedSizeShifts: [Int: Int] = [:]
    var comment = Data()

    init(_ files: [File]) {
        self.files = files
    }

    func build() -> Data {
        var archive = Data()
        var central = Data()
        for (position, file) in files.enumerated() {
            let compressed = file.rawData ?? (file.method == 8 ? Self.deflate(file.contents) : file.contents)
            let checksum = file.declaredChecksum ?? Self.crc32(file.contents)
            let size = file.declaredSize ?? file.contents.count
            let nameBytes = Data(file.name.utf8)
            let localNameBytes = Data((file.localName ?? file.name).utf8)
            let offset = archive.count

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20))
            archive.append(le16(file.flags))
            archive.append(le16(file.localMethod ?? file.method))
            archive.append(le16(0))
            archive.append(le16(0x5D6E))
            archive.append(le32(checksum))
            archive.append(le32(UInt32(compressed.count)))
            archive.append(le32(UInt32(truncatingIfNeeded: size)))
            archive.append(le16(UInt16(localNameBytes.count)))
            archive.append(le16(0))
            archive.append(localNameBytes)
            archive.append(compressed)

            let compressedSize = compressed.count + (compressedSizeShifts[position] ?? 0)
            central.append(le32(0x0201_4B50))
            central.append(le16(UInt16(file.host) << 8 | 20))
            central.append(le16(20))
            central.append(le16(file.flags))
            central.append(le16(file.method))
            central.append(le16(0))
            central.append(le16(0x5D6E))
            central.append(le32(checksum))
            central.append(le32(UInt32(truncatingIfNeeded: compressedSize)))
            central.append(le32(UInt32(truncatingIfNeeded: size)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(file.externalAttributes))
            central.append(le32(UInt32(truncatingIfNeeded: offset + (headerOffsetShifts[position] ?? 0))))
            central.append(nameBytes)
        }
        let directoryOffset = archive.count
        archive.append(central)
        let count = UInt16(truncatingIfNeeded: entryCount ?? files.count)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0))
        archive.append(le16(0))
        archive.append(le16(count))
        archive.append(le16(count))
        archive.append(le32(UInt32(truncatingIfNeeded: central.count + directorySizeShift)))
        archive.append(le32(UInt32(truncatingIfNeeded: directoryOffset + directoryOffsetShift)))
        archive.append(le16(UInt16(comment.count)))
        archive.append(comment)
        return archive
    }

    /// Raw deflate, as ZIP stores it, through the Compression framework's encoder.
    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0, "the test's deflate failed")
        output.count = written
        return output
    }

    /// CRC-32 bit by bit, unlike the reader's table.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
}

private func le32(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
}

private func le32(_ value: Int) -> Data {
    le32(UInt32(truncatingIfNeeded: value))
}

/// An Alfred collection in memory: one JSON file per snippet and an optional `info.plist`.
enum AlfredFixture {
    struct Snippet {
        var name: String
        var text: String
        var keyword: String
        var dontAutoExpand: Bool?
        var uid = UUID().uuidString

        init(_ name: String, _ text: String, keyword: String = "", dontAutoExpand: Bool? = nil) {
            self.name = name
            self.text = text
            self.keyword = keyword
            self.dontAutoExpand = dontAutoExpand
        }

        var json: Data {
            var snippet: [String: Any] = ["snippet": text, "uid": uid, "name": name, "keyword": keyword]
            if let dontAutoExpand { snippet["dontautoexpand"] = dontAutoExpand }
            return try! JSONSerialization.data(withJSONObject: ["alfredsnippet": snippet], options: [.sortedKeys])
        }
    }

    static func archive(_ snippets: [Snippet], prefix: String? = nil, suffix: String? = nil) -> Data {
        var files = snippets.map { ZipBuilder.File("\($0.name) [\($0.uid)].json", $0.json) }
        if prefix != nil || suffix != nil {
            var settings: [String: Any] = [:]
            if let prefix { settings["snippetkeywordprefix"] = prefix }
            if let suffix { settings["snippetkeywordsuffix"] = suffix }
            let plist = try! PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            files.append(ZipBuilder.File("info.plist", plist))
        }
        return ZipBuilder(files).build()
    }
}
