import Compression
import Foundation

/// A ZIP archive held in memory, read through its central directory. It writes nothing to disk.
///
/// It reads archives a person picked, so it trusts nothing in them. It accepts only:
///
/// - plain files at the top level: no folder, no link, and no name with a separator, a control
///   character, `.` or `..`;
/// - entries that are stored or compressed with deflate, unencrypted, on one disk, without ZIP64;
/// - at most ``Limits/maximumEntries`` entries, each at most ``Limits/maximumEntrySize`` bytes and
///   all together at most ``Limits/maximumTotalSize`` bytes, as declared;
/// - a central directory that ends where the end record starts, with every entry's local header
///   inside the file, agreeing with it, and not overlapping another entry.
///
/// Anything else throws, and nothing of the archive is used. ``contents(of:)`` inflates one entry
/// into a buffer one byte larger than its declared size, and throws unless it ends at exactly that
/// size with the declared checksum.
nonisolated struct ZipArchive: Sendable {
    struct Limits: Hashable, Sendable {
        var maximumEntries = 5_000
        var maximumEntrySize = 1_048_576
        var maximumTotalSize = 52_428_800
    }

    enum Method: Hashable, Sendable {
        case stored
        case deflated
    }

    /// One file in the archive, as the central directory declares it.
    struct Entry: Hashable, Sendable {
        /// The name as written, decoded as UTF-8 with replacement characters for anything else.
        let name: String
        let method: Method
        let checksum: UInt32
        let compressedSize: Int
        /// The size after inflation.
        let size: Int
        /// Where the local header starts.
        let headerOffset: Int
        /// Where the entry's data starts, after its local header.
        let dataOffset: Int
    }

    let entries: [Entry]
    private let bytes: Data

    /// True when the data starts like a ZIP archive: a local header, or the end record of an empty
    /// archive.
    static func looksLikeArchive(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4))
        return head == [0x50, 0x4B, 0x03, 0x04] || head == [0x50, 0x4B, 0x05, 0x06]
    }

    init(_ data: Data, limits: Limits = Limits()) throws(ZipError) {
        // Offsets below count from zero.
        let bytes = data.startIndex == 0 ? data : Data(data)
        self.bytes = bytes
        let reader = ByteReader(bytes)
        guard let end = Self.endRecord(in: reader) else { throw .notAnArchive }
        let thisDisk = reader.u16(end + 4)
        let directoryDisk = reader.u16(end + 6)
        let entriesOnDisk = reader.u16(end + 8)
        let entryCount = reader.u16(end + 10)
        let directorySize = reader.u32(end + 12)
        let directoryOffset = reader.u32(end + 16)
        guard thisDisk == 0, directoryDisk == 0, entriesOnDisk == entryCount else { throw .unsupported }
        // ZIP64 marks its fields with all bits set and puts a locator just before the end record.
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
            !(end >= 20 && reader.u32(end - 20) == Signature.zip64Locator)
        else { throw .unsupported }
        guard entryCount <= limits.maximumEntries else { throw .tooManyEntries }
        guard directoryOffset <= end, directorySize == end - directoryOffset else { throw .damaged }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var names = Set<String>()
        var totalSize = 0
        var position = directoryOffset
        for _ in 0..<entryCount {
            let entry = try Self.entry(
                at: position, in: reader, directory: directoryOffset..<end, limits: limits)
            totalSize += entry.entry.size
            guard totalSize <= limits.maximumTotalSize else { throw .tooLarge }
            guard names.insert(entry.entry.name).inserted else { throw .damaged }
            entries.append(entry.entry)
            position = entry.next
        }
        guard position == end else { throw .damaged }
        // Two entries that share bytes are a sign of a crafted archive.
        let byOffset = entries.sorted { $0.headerOffset < $1.headerOffset }
        for (earlier, later) in zip(byOffset, byOffset.dropFirst())
        where later.headerOffset < earlier.dataOffset + earlier.compressedSize {
            throw .damaged
        }
        self.entries = entries
    }

    /// The entry's contents, inflated and checked against its declared size and checksum.
    func contents(of entry: Entry) throws(ZipError) -> Data {
        let compressed = bytes[entry.dataOffset..<(entry.dataOffset + entry.compressedSize)]
        let output: Data
        switch entry.method {
        case .stored:
            output = Data(compressed)
        case .deflated:
            output = try Self.inflate(compressed, size: entry.size, name: entry.name)
        }
        guard output.count == entry.size, CRC32.checksum(output) == entry.checksum else {
            throw .contentsDoNotMatch(entry.name)
        }
        return output
    }

    // MARK: Reading the directory

    private enum Signature {
        static let localHeader = 0x0403_4B50
        static let centralHeader = 0x0201_4B50
        static let endRecord = 0x0605_4B50
        static let zip64Locator = 0x0706_4B50
    }

    /// The end record: the last one whose comment ends exactly at the end of the data.
    private static func endRecord(in reader: ByteReader) -> Int? {
        let fixedLength = 22
        guard reader.count >= fixedLength else { return nil }
        let lowest = max(0, reader.count - fixedLength - 0xFFFF)
        var position = reader.count - fixedLength
        while position >= lowest {
            if reader.u32(position) == Signature.endRecord,
                position + fixedLength + reader.u16(position + 20) == reader.count
            {
                return position
            }
            position -= 1
        }
        return nil
    }

    /// One central directory entry and the position of the next, checked against its local header.
    private static func entry(at position: Int, in reader: ByteReader, directory: Range<Int>, limits: Limits)
        throws(ZipError) -> (entry: Entry, next: Int)
    {
        guard reader.contains(position, length: 46), reader.u32(position) == Signature.centralHeader else {
            throw .damaged
        }
        let host = reader.u16(position + 4) >> 8
        let flags = reader.u16(position + 8)
        let methodCode = reader.u16(position + 10)
        let checksum = UInt32(reader.u32(position + 16))
        let compressedSize = reader.u32(position + 20)
        let size = reader.u32(position + 24)
        let nameLength = reader.u16(position + 28)
        let extraLength = reader.u16(position + 30)
        let commentLength = reader.u16(position + 32)
        let startDisk = reader.u16(position + 34)
        let externalAttributes = reader.u32(position + 38)
        let headerOffset = reader.u32(position + 42)
        let next = position + 46 + nameLength + extraLength + commentLength
        guard next <= directory.upperBound else { throw .damaged }
        let nameBytes = reader.slice(position + 46, length: nameLength)
        let name = String(decoding: nameBytes, as: UTF8.self)

        guard isPlainFileName(nameBytes), !isFolderOrLink(host: host, attributes: externalAttributes) else {
            throw .unsafeEntry(name)
        }
        // Bit 0 is encryption, bit 6 strong encryption, bit 13 an encrypted directory.
        guard startDisk == 0, flags & 0x2041 == 0 else { throw .unsupported }
        guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, headerOffset != 0xFFFF_FFFF else {
            throw .unsupported
        }
        let method: Method
        switch methodCode {
        case 0: method = .stored
        case 8: method = .deflated
        default: throw .unsupported
        }
        guard size <= limits.maximumEntrySize else { throw .tooLarge }
        if method == .stored, compressedSize != size { throw .damaged }

        // The local header must be where the directory says, and say the same.
        guard reader.contains(headerOffset, length: 30), reader.u32(headerOffset) == Signature.localHeader else {
            throw .damaged
        }
        let localFlags = reader.u16(headerOffset + 6)
        let localMethod = reader.u16(headerOffset + 8)
        let localNameLength = reader.u16(headerOffset + 26)
        let localExtraLength = reader.u16(headerOffset + 28)
        guard localFlags & 0x2041 == 0, localMethod == methodCode, localNameLength == nameLength,
            reader.contains(headerOffset + 30, length: localNameLength),
            reader.slice(headerOffset + 30, length: localNameLength) == nameBytes
        else { throw .damaged }
        let dataOffset = headerOffset + 30 + localNameLength + localExtraLength
        // The data lies before the central directory.
        guard dataOffset <= directory.lowerBound, compressedSize <= directory.lowerBound - dataOffset else {
            throw .damaged
        }
        let entry = Entry(
            name: name, method: method, checksum: checksum, compressedSize: compressedSize, size: size,
            headerOffset: headerOffset, dataOffset: dataOffset)
        return (entry, next)
    }

    /// A name that is one plain file at the top level.
    static func isPlainFileName(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 255, bytes != [0x2E], bytes != [0x2E, 0x2E] else { return false }
        return !bytes.contains { $0 == 0x2F || $0 == 0x5C || $0 < 0x20 || $0 == 0x7F }
    }

    /// True for a folder or a link: the Unix file type for archives made on Unix or macOS, and the
    /// MS-DOS folder bit for any.
    static func isFolderOrLink(host: Int, attributes: Int) -> Bool {
        if attributes & 0x10 != 0 { return true }
        guard host == 3 || host == 19 else { return false }
        let type = (attributes >> 16) & 0xF000
        return type != 0 && type != 0x8000
    }

    // MARK: Inflating

    /// Raw deflate, as ZIP stores it, into a buffer one byte larger than the declared size. Throws
    /// when the stream is damaged, stops before its end, or would grow past the declared size.
    private static func inflate(_ compressed: Data, size: Int, name: String) throws(ZipError) -> Data {
        guard !compressed.isEmpty else { throw .contentsDoNotMatch(name) }
        let capacity = size + 1
        var output = Data(count: capacity)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw .contentsDoNotMatch(name) }
        defer { compression_stream_destroy(stream) }
        let produced: Int? = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceStart = source.bindMemory(to: UInt8.self).baseAddress,
                    let destinationStart = destination.bindMemory(to: UInt8.self).baseAddress
                else { return nil }
                stream.pointee.src_ptr = sourceStart
                stream.pointee.src_size = source.count
                stream.pointee.dst_ptr = destinationStart
                stream.pointee.dst_size = capacity
                let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                while true {
                    let before = (stream.pointee.src_size, stream.pointee.dst_size)
                    let status = compression_stream_process(stream, finalize)
                    if status == COMPRESSION_STATUS_END { return capacity - stream.pointee.dst_size }
                    guard status == COMPRESSION_STATUS_OK, stream.pointee.dst_size > 0,
                        before != (stream.pointee.src_size, stream.pointee.dst_size)
                    else { return nil }
                }
            }
        }
        guard let produced, produced == size else { throw .contentsDoNotMatch(name) }
        output.count = produced
        return output
    }
}

/// Why an archive was refused.
nonisolated enum ZipError: Error, Hashable, Sendable {
    /// No end record: not a ZIP archive, or one cut short.
    case notAnArchive
    /// Headers that disagree, point outside the file, overlap or repeat a name.
    case damaged
    /// Encryption, ZIP64, several disks, or a method other than stored or deflate.
    case unsupported
    /// A folder, a link, or a name that is not a plain file name.
    case unsafeEntry(String)
    case tooManyEntries
    /// An entry, or all of them together, declared larger than the limits.
    case tooLarge
    /// An entry that does not inflate to its declared size and checksum.
    case contentsDoNotMatch(String)
}

/// Little-endian reads with bounds the caller checks first.
private nonisolated struct ByteReader {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var count: Int { data.count }

    /// True when `length` bytes from `offset` lie inside the data.
    func contains(_ offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    /// Zero outside the data, so a read past the end never traps; callers check bounds first.
    func u16(_ offset: Int) -> Int {
        guard contains(offset, length: 2) else { return 0 }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> Int {
        guard contains(offset, length: 4) else { return 0 }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16
            | Int(data[offset + 3]) << 24
    }

    func slice(_ offset: Int, length: Int) -> [UInt8] {
        guard contains(offset, length: length) else { return [] }
        return [UInt8](data[offset..<(offset + length)])
    }
}

/// The CRC-32 that ZIP uses, with the reflected polynomial 0xEDB88320.
nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
