import Foundation

/// A file's bytes as note text, or nil for a file that is not text. Pure.
///
/// UTF-8 with or without a byte order mark, and UTF-16 with one, as TextEdit can save. A NUL in the
/// first 8 KB, or bytes that are mostly not UTF-8, mean the file is not text: an image or an
/// archive renamed to `.md` is left out rather than shown as noise. A read cut at the size limit may
/// end inside a character; that partial character is dropped.
nonisolated enum NoteDecoding {
    static func text(_ data: Data, isCut: Bool) -> String? {
        var bytes = data[...]
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = bytes.first == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            var body = bytes.dropFirst(2)
            if body.count % 2 == 1 { body = body.dropLast() }
            if let text = String(data: Data(body), encoding: encoding) { return text }
            // A cut may leave half of a surrogate pair at the end.
            guard isCut, body.count >= 2 else { return nil }
            return String(data: Data(body.dropLast(2)), encoding: encoding)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if bytes.prefix(8_192).contains(0) { return nil }
        if isCut { bytes = withoutPartialCharacter(bytes) }
        let text = String(decoding: bytes, as: UTF8.self)
        let sample = text.unicodeScalars.prefix(4_096)
        var replaced = 0
        var total = 0
        for scalar in sample {
            total += 1
            if scalar == "\u{FFFD}" { replaced += 1 }
        }
        if replaced > 16, replaced * 20 > total { return nil }
        return text
    }

    /// How a file's bytes stand to the text read from them. `isExact` is true when the bytes are the
    /// text in UTF-8, after a UTF-8 byte order mark when `byteOrderMark` is true, so writing the text
    /// back, with the mark, changes nothing else. A file in UTF-16, one with bytes that are not
    /// UTF-8, and a read cut short are not exact: writing their text back would change bytes the
    /// user never touched.
    static func roundTrip(_ data: Data, text: String) -> (isExact: Bool, byteOrderMark: Bool) {
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasMark = data.starts(with: mark)
        let body = hasMark ? data.dropFirst(mark.count) : data[...]
        var text = text
        let isExact = text.withUTF8 { utf8 in
            body.withUnsafeBytes { raw in
                raw.count == utf8.count && (utf8.isEmpty || memcmp(raw.baseAddress, utf8.baseAddress, utf8.count) == 0)
            }
        }
        return (isExact, hasMark)
    }

    /// The bytes without a UTF-8 sequence cut short at the end.
    static func withoutPartialCharacter(_ bytes: Data.SubSequence) -> Data.SubSequence {
        var start = bytes.endIndex
        var continuation = 0
        while start > bytes.startIndex, continuation < 4 {
            let byte = bytes[bytes.index(before: start)]
            start = bytes.index(before: start)
            if byte & 0xC0 == 0x80 {
                continuation += 1
                continue
            }
            let length =
                switch byte {
                case 0x00..<0x80: 1
                case 0xC0..<0xE0: 2
                case 0xE0..<0xF0: 3
                case 0xF0..<0xF8: 4
                default: 1
                }
            return continuation + 1 < length ? bytes[..<start] : bytes
        }
        return bytes
    }
}
