import Foundation

/// Decodes UTF-8 that arrives in chunks, such as a process's output or a streamed response.
///
/// Chunks follow neither character nor line boundaries, so decoding each on its own turns a
/// character split across two chunks into two replacement marks. This keeps an incomplete trailing
/// sequence until the next chunk completes it.
public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The text of every complete character so far.
    public mutating func decode(_ chunk: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: chunk)
        let complete = Self.completeLength(bytes)
        pending = Array(bytes[complete...])
        return String(decoding: bytes[..<complete], as: UTF8.self)
    }

    /// Whatever is left at the end of the stream, with invalid bytes shown as replacement marks.
    public mutating func finish() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }

    /// The length of the longest prefix that does not end inside a multi-byte character.
    private static func completeLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count
        while index > 0 && bytes.count - index < 4 {
            index -= 1
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return index + length <= bytes.count ? bytes.count : index
        }
        return bytes.count
    }
}

/// Splits bytes that arrive in chunks into lines, decoding each line only once it is whole.
public struct LineSplitter: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The lines this chunk completes, without their line breaks. A `\r\n` ending counts as one break.
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(contentsOf: chunk)
        var lines: [String] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var end = newline
            if end > start && pending[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            lines.append(String(decoding: pending[start..<end], as: UTF8.self))
            start = newline + 1
        }
        pending.removeSubrange(..<start)
        return lines
    }

    /// The last line when the stream ended without a line break, or nil.
    public mutating func finish() -> String? {
        defer { pending = [] }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
