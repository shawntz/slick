/// A run's output as a page keeps it: the newest output, at most ``limit`` UTF-8 bytes.
///
/// Output appends while it fits. When a chunk takes it past the limit, the oldest output is dropped
/// down to three quarters of the limit, so the page is replaced once per quarter of the limit and
/// not on every chunk. The cut falls after a line break when one is near, so the kept text starts on
/// a line of its own and no escape sequence is split; otherwise on a character boundary. Standard
/// output and standard error share the buffer in the order they arrived.
nonisolated struct OutputBuffer: Sendable {
    /// What an append did to the text.
    enum Change: Hashable, Sendable {
        /// The chunk was added at the end.
        case appended
        /// The chunk was added and the start was dropped, so the whole text changed.
        case trimmed
    }

    let limit: Int
    /// The output kept now.
    private(set) var text = ""
    /// UTF-8 bytes in ``text``.
    private(set) var count = 0
    /// UTF-8 bytes dropped from the start, in all.
    private(set) var dropped = 0

    init(limit: Int) {
        self.limit = max(limit, 16)
    }

    /// The kept text from a UTF-8 offset to the end. The offset falls where an earlier append ended,
    /// so on a scalar boundary.
    func text(fromByte offset: Int) -> String {
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: min(max(0, offset), count))
        return String(text.unicodeScalars[start...])
    }

    mutating func append(_ chunk: String) -> Change {
        text += chunk
        count += chunk.utf8.count
        guard count > limit else { return .appended }
        trim(to: limit - limit / 4)
        return .trimmed
    }

    /// Drops the oldest output so that at most `target` bytes stay.
    private mutating func trim(to target: Int) {
        let bytes = text.utf8
        var cut = bytes.index(bytes.startIndex, offsetBy: count - target)
        let slack = limit / 4
        if let lineBreak = bytes[cut...].prefix(slack).firstIndex(of: UInt8(ascii: "\n")) {
            cut = bytes.index(after: lineBreak)
        } else {
            while cut < bytes.endIndex, UTF8.isContinuation(bytes[cut]) {
                cut = bytes.index(after: cut)
            }
        }
        let removed = bytes.distance(from: bytes.startIndex, to: cut)
        text = String(text.unicodeScalars[cut...])
        dropped += removed
        count -= removed
    }
}
