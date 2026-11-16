import Foundation
import Testing

@testable import Snippets

/// The ZIP reader against archives built here, honest and hostile. Nothing is read from or written
/// to disk.
@Suite("Reading ZIP archives", .timeLimit(.minutes(1)))
struct ZipArchiveTests {
    private func read(_ data: Data, limits: ZipArchive.Limits = ZipArchive.Limits()) throws(ZipError) -> [String: Data]
    {
        let archive = try ZipArchive(data, limits: limits)
        var contents: [String: Data] = [:]
        for entry in archive.entries {
            contents[entry.name] = try archive.contents(of: entry)
        }
        return contents
    }

    private func refusal(_ data: Data, limits: ZipArchive.Limits = ZipArchive.Limits()) -> ZipError? {
        do {
            _ = try read(data, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    private let text = String(repeating: "Thanks for writing. ", count: 40)

    @Test func storedAndDeflatedEntriesReadBack() throws {
        let data = ZipBuilder([
            .init("one.json", text: text, method: 8),
            .init("two.json", text: "short", method: 0),
            .init("empty.txt", Data(), method: 0),
        ]).build()
        let archive = try ZipArchive(data)
        #expect(archive.entries.map(\.name) == ["one.json", "two.json", "empty.txt"])
        #expect(archive.entries.map(\.method) == [.deflated, .stored, .stored])
        #expect(archive.entries[0].compressedSize < archive.entries[0].size, "the text compresses")
        #expect(try read(data) == ["one.json": Data(text.utf8), "two.json": Data("short".utf8), "empty.txt": Data()])
    }

    /// Made once with `/usr/bin/zip -X` from three synthetic files, and once with `ditto -c -k`,
    /// which writes data descriptors and extra fields, to check the reader against real tools.
    @Test func archivesFromTheSystemsZipToolsRead() throws {
        let zip = try #require(Data(base64Encoded: SystemArchives.zipTool))
        let names = try ZipArchive(zip).entries.map(\.name)
        #expect(names == ["Thanks [A1].json", "Stamp [B2].json", "info.plist"])
        let contents = try read(zip)
        #expect(
            String(decoding: contents["Stamp [B2].json"] ?? Data(), as: UTF8.self).contains("\"keyword\":\"stamp\""))
        #expect(contents["info.plist"]?.count == 293)

        let ditto = try #require(Data(base64Encoded: SystemArchives.ditto))
        let dittoContents = try read(ditto)
        #expect(dittoContents.keys.sorted() == ["Thanks [A1].json"])
        #expect(dittoContents["Thanks [A1].json"] == contents["Thanks [A1].json"])
    }

    @Test func aPathThatClimbsOutIsRefused() {
        for name in ["../escape.json", "..", ".", "a/../../escape.json"] {
            let data = ZipBuilder([.init("good.json", text: "{}"), .init(name, text: "{}")]).build()
            #expect(refusal(data) == .unsafeEntry(name), "\(name)")
        }
    }

    @Test func aNameWithASeparatorIsRefused() {
        for name in ["folder/inner.json", "folder\\inner.json", "/absolute.json", "folder/", "tab\there.json", ""] {
            let data = ZipBuilder([.init(name, text: "{}")]).build()
            #expect(refusal(data) == .unsafeEntry(name), "\(name.debugDescription)")
        }
    }

    @Test func foldersAndLinksAreRefusedByTheirAttributes() {
        var folder = ZipBuilder.File("plain", Data(), method: 0)
        folder.externalAttributes = 0o040755 << 16
        var link = ZipBuilder.File("link.json", Data("/etc/hosts".utf8), method: 0)
        link.externalAttributes = 0o120777 << 16
        var dosFolder = ZipBuilder.File("dos", Data(), method: 0)
        dosFolder.host = 0
        dosFolder.externalAttributes = 0x10
        var device = ZipBuilder.File("device", Data(), method: 0)
        device.externalAttributes = 0o020644 << 16
        for file in [folder, link, dosFolder, device] {
            #expect(refusal(ZipBuilder([file]).build()) == .unsafeEntry(file.name), "\(file.name)")
        }
        // A file from an MS-DOS host has no Unix type to read.
        var dosFile = ZipBuilder.File("dos.json", Data("{}".utf8), method: 0)
        dosFile.host = 0
        dosFile.externalAttributes = 0x20
        #expect(refusal(ZipBuilder([dosFile]).build()) == nil)
    }

    @Test func anEntryThatInflatesPastItsDeclaredSizeIsRefused() throws {
        var file = ZipBuilder.File("big.json", text: text)
        file.declaredSize = 100
        let archive = try ZipArchive(ZipBuilder([file]).build())
        #expect(throws: ZipError.contentsDoNotMatch("big.json")) { try archive.contents(of: archive.entries[0]) }

        // Short of its declared size, or with another checksum, it is refused too.
        file.declaredSize = text.utf8.count + 1
        let short = try ZipArchive(ZipBuilder([file]).build())
        #expect(throws: ZipError.contentsDoNotMatch("big.json")) { try short.contents(of: short.entries[0]) }
        var corrupt = ZipBuilder.File("big.json", text: text)
        corrupt.declaredChecksum = 1
        let checked = try ZipArchive(ZipBuilder([corrupt]).build())
        #expect(throws: ZipError.contentsDoNotMatch("big.json")) { try checked.contents(of: checked.entries[0]) }
        var stored = ZipBuilder.File("stored.json", text: "abc", method: 0)
        stored.declaredChecksum = 7
        let storedArchive = try ZipArchive(ZipBuilder([stored]).build())
        #expect(throws: ZipError.contentsDoNotMatch("stored.json")) {
            try storedArchive.contents(of: storedArchive.entries[0])
        }
    }

    @Test func aDeflateStreamCutShortIsRefused() throws {
        let deflated = ZipBuilder.deflate(Data(text.utf8))
        for cut in [1, deflated.count / 2, deflated.count - 1] {
            var file = ZipBuilder.File("cut.json", text: text)
            file.rawData = deflated.prefix(cut)
            let archive = try ZipArchive(ZipBuilder([file]).build())
            #expect(throws: ZipError.contentsDoNotMatch("cut.json")) { try archive.contents(of: archive.entries[0]) }
        }
    }

    @Test func aTruncatedFileIsRefusedAtEveryLength() {
        let data = ZipBuilder([.init("one.json", text: text), .init("two.json", text: "two", method: 0)]).build()
        for length in 0..<data.count {
            #expect(refusal(data.prefix(length)) != nil, "cut to \(length) bytes")
        }
        // Bytes missing from the middle move every offset after them.
        var middle = data
        middle.removeSubrange(10..<20)
        #expect(refusal(middle) != nil)
    }

    @Test func aCentralDirectoryThatLiesIsRefused() {
        let files: [ZipBuilder.File] = [.init("one.json", text: text), .init("two.json", text: "two", method: 0)]
        var more = ZipBuilder(files)
        more.entryCount = 3
        var fewer = ZipBuilder(files)
        fewer.entryCount = 1
        var offset = ZipBuilder(files)
        offset.directoryOffsetShift = -4
        var size = ZipBuilder(files)
        size.directorySizeShift = 8
        var header = ZipBuilder(files)
        header.headerOffsetShifts = [1: 100_000]
        var intoDirectory = ZipBuilder([.init("one.json", text: text), .init("two.json", text: text)])
        intoDirectory.compressedSizeShifts = [1: 64]
        var overlapping = ZipBuilder(files)
        overlapping.compressedSizeShifts = [0: 10]
        var otherName = files
        otherName[1].localName = "six.json"
        var otherMethod = files
        otherMethod[1].localMethod = 8
        var twice = files
        twice[1].name = "one.json"
        var cases: [(String, ZipBuilder)] = [
            ("more entries", more), ("fewer entries", fewer), ("directory offset", offset), ("directory size", size),
            ("header offset", header), ("data into the directory", intoDirectory), ("overlap", overlapping),
            ("local name", ZipBuilder(otherName)), ("local method", ZipBuilder(otherMethod)),
            ("same name twice", ZipBuilder(twice)),
        ]
        var stored = files
        stored[1].declaredSize = 2
        cases.append(("stored sizes differ", ZipBuilder(stored)))
        for (label, builder) in cases {
            #expect(refusal(builder.build()) == .damaged, "\(label)")
        }
    }

    @Test func garbageIsRefused() throws {
        var generator = SeededGenerator(seed: 7)
        for length in [0, 1, 4, 21, 22, 100, 4096] {
            let noise = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(refusal(noise) != nil, "\(length) random bytes")
            #expect(refusal(Data([0x50, 0x4B, 0x03, 0x04]) + noise) != nil, "a local header then \(length) bytes")
        }
        // An end record alone is an empty archive, which holds nothing.
        let empty = ZipBuilder([]).build()
        #expect(try ZipArchive(empty).entries.isEmpty)
        // A comment that does not reach the end, or runs past it, is no end record.
        var comment = ZipBuilder([.init("a.json", text: "{}")])
        comment.comment = Data("note".utf8)
        var data = comment.build()
        #expect(refusal(data) == nil)
        data.append(0)
        #expect(refusal(data) == .notAnArchive)
    }

    @Test func encryptionOtherMethodsAndZip64AreRefused() {
        var encrypted = ZipBuilder.File("secret.json", text: "{}", method: 0)
        encrypted.flags = 1
        let bzip2 = ZipBuilder.File("other.json", text: "{}", method: 12)
        var zip64 = ZipBuilder.File("huge.json", text: "{}", method: 0)
        zip64.declaredSize = 0xFFFF_FFFF
        for file in [encrypted, bzip2] {
            #expect(refusal(ZipBuilder([file]).build()) == .unsupported, "\(file.name)")
        }
        #expect(refusal(ZipBuilder([zip64]).build()) == .unsupported)
        var marked = ZipBuilder([.init("a.json", text: "{}")])
        marked.entryCount = 0xFFFF
        #expect(refusal(marked.build()) == .unsupported)
    }

    @Test func limitsAreCheckedBeforeAnythingInflates() throws {
        // More than 5,000 entries.
        let many = ZipBuilder((0...5_000).map { ZipBuilder.File("\($0).json", Data(), method: 0) }).build()
        #expect(refusal(many) == .tooManyEntries)
        let enough = ZipBuilder((0..<5_000).map { ZipBuilder.File("\($0).json", Data(), method: 0) }).build()
        #expect(try ZipArchive(enough).entries.count == 5_000)

        // One entry declared over 1 MB, though its data is tiny.
        var big = ZipBuilder.File("big.json", text: "{}")
        big.declaredSize = 1_048_577
        #expect(refusal(ZipBuilder([big]).build()) == .tooLarge)

        // Fifty-one entries of 1 MB each, declared, are more than 50 MB in all.
        let total = ZipBuilder(
            (0..<51).map { index in
                var file = ZipBuilder.File("\(index).json", text: "{}")
                file.declaredSize = 1_048_576
                return file
            }
        ).build()
        #expect(refusal(total) == .tooLarge)

        // Smaller limits apply the same way.
        let small = ZipArchive.Limits(maximumEntries: 1, maximumEntrySize: 10, maximumTotalSize: 15)
        #expect(refusal(ZipBuilder([.init("a", text: "12345678901")]).build(), limits: small) == .tooLarge)
        #expect(
            refusal(ZipBuilder([.init("a", text: "1"), .init("b", text: "2")]).build(), limits: small)
                == .tooManyEntries)
    }

    @Test func aDeflateBombStopsAtTheDeclaredSize() throws {
        // A megabyte of zeros deflates to about a kilobyte. Declared as 1,000 bytes, the reader stops
        // one byte past that and refuses.
        let zeros = Data(count: 1_048_576)
        var bomb = ZipBuilder.File("zeros.json", zeros)
        bomb.declaredSize = 1_000
        let archive = try ZipArchive(ZipBuilder([bomb]).build())
        #expect(archive.entries[0].compressedSize < 2_000)
        #expect(throws: ZipError.contentsDoNotMatch("zeros.json")) { try archive.contents(of: archive.entries[0]) }
    }

    @Test func checksumsMatchKnownValues() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data(text.utf8)) == ZipBuilder.crc32(Data(text.utf8)))
    }
}

/// A random number generator that repeats, so a failure can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Archives made by the system's own tools from synthetic files, kept as base64.
enum SystemArchives {
    /// `/usr/bin/zip -X` of `Thanks [A1].json`, `Stamp [B2].json` and `info.plist`, all deflated.
    static let zipTool =
        "UEsDBBQAAAAIAMALbl0cAkjiUgAAAIwAAAAQAAAAVGhhbmtzIFtBMV0uanNvbqtWSsxJK0pNKc7LLChILVGyqlaCM5VCMhLzsosV0vKLFMqLMksy89L1YvJi8ogXVtJRKs1MAZrkaAhk5iXmpsJNBfKzUyvL84tA0iUZFUq1tQBQSwMEFAAAAAgAwAtuXdv59x1cAAAAdAAAAA8AAABTdGFtcCBbQjJdLmpzb249yTEKgDAMheGrSGYnR0ev4AmiiVC0bWhTVErvbgRx+9/7KuCxJaYcnAgrjBX+hEqo3Lq6Hk6WiIka9FAcGU2DZUDP1rOiF5s732dMr+bvoRgUi0a+BIOBpsKtPVBLAwQUAAAACADAC25dRoV7s8QAAAAlAQAACgAAAGluZm8ucGxpc3RtjlELgjAUhZ/zV6y96623qDWpNBCkhOyhx3CrRurGtlL/fTODCHo73Hu+cw4J26pET66NkPUST4MJRrwuJBP1dYmP+daf4ZB6ZBztN/kpi5EqhbEoO67TZIOwD7BSquQAUR6hLE0OOXIZAPEOI3yzVs0BmqYJzr0rKGTVGw1kWiqubZe6MN8BAbMMu5oh/WeOuzJRWOqNyJ131NRCKW6dbKRmSvOLaAn0H2cwVrvddEHgo/5C5nH5A30ZAkMhgfcc6r0AUEsBAh4DFAAAAAgAwAtuXRwCSOJSAAAAjAAAABAAAAAAAAAAAQAAAKSBAAAAAFRoYW5rcyBbQTFdLmpzb25QSwECHgMUAAAACADAC25d2/n3HVwAAAB0AAAADwAAAAAAAAABAAAApIGAAAAAU3RhbXAgW0IyXS5qc29uUEsBAh4DFAAAAAgAwAtuXUaFe7PEAAAAJQEAAAoAAAAAAAAAAQAAAKSBCQEAAGluZm8ucGxpc3RQSwUGAAAAAAMAAwCzAAAA9QEAAAAA"

    /// `ditto -c -k --norsrc` of `Thanks [A1].json`: a data descriptor and a time extra field. The
    /// owner fields of the extra field are zeroed.
    static let ditto =
        "UEsDBBQACAAIAMALbl0AAAAAAAAAAAAAAAAQABAAVGhhbmtzIFtBMV0uanNvblVYDAAYKvhqGCr4agAAAACrVkrMSStKTSnOyywoSC1RsqpWgjOVQjIS87KLFdLyixTKizJLMvPS9WLyYvKIF1bSUSrNTAGa5GgIZOYl5qbCTQXys1Mry/OLQNIlGRVKtbUAUEsHCBwCSOJSAAAAjAAAAFBLAQIVAxQACAAIAMALbl0cAkjiUgAAAIwAAAAQAAwAAAAAAAAAAECkgQAAAABUaGFua3MgW0ExXS5qc29uVVgIABgq+GoYKvhqUEsFBgAAAAABAAEASgAAAKAAAAAAAA=="
}
