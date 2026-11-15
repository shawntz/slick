import SlickCoreC

/// Reusable query state and output storage. Make one per panel and reuse it for every keystroke:
/// it holds the session that narrows from the previous query, the hit buffer, scratch space for
/// strings without contiguous UTF-8, and the highlight and completion buffers. After the first few
/// queries nothing allocates.
///
/// Not `Sendable`: a buffer belongs to whoever runs its queries, normally the main actor. It works
/// with the engine and with every fuzzy index.
public final class QueryBuffer {
    /// The most hits one query returns.
    public let capacity: Int
    /// Hits of the last query.
    public private(set) var count = 0
    let session: OpaquePointer
    let hits: UnsafeMutableBufferPointer<SlickHit>
    let ranges: UnsafeMutableBufferPointer<SlickRange>
    let text: UnsafeMutableBufferPointer<UInt8>
    private let scratch: UnsafeMutableBufferPointer<UInt8>

    /// A buffer for at most `capacity` hits.
    public init(capacity: Int = 50) throws(CoreError) {
        var handle: OpaquePointer?
        try CoreError.check(slick_session_new(&handle))
        guard let handle else { throw .nullPointer }
        session = handle
        self.capacity = max(capacity, 1)
        hits = .allocate(capacity: self.capacity)
        hits.initialize(repeating: SlickHit())
        ranges = .allocate(capacity: 64)
        ranges.initialize(repeating: SlickRange())
        text = .allocate(capacity: 1024)
        text.initialize(repeating: 0)
        scratch = .allocate(capacity: 1024)
        scratch.initialize(repeating: 0)
    }

    deinit {
        slick_session_free(session)
        hits.deallocate()
        ranges.deallocate()
        text.deallocate()
        scratch.deallocate()
    }

    /// The hit at `index`, best first.
    public subscript(index: Int) -> Hit {
        precondition(index >= 0 && index < count, "hit index out of range")
        return Hit(hits[index])
    }

    /// Forgets earlier queries, so the next one scans everything. Call it on summon.
    public func reset() {
        slick_session_reset(session)
        count = 0
    }

    /// Runs `body` with `string`'s UTF-8. Native strings and bridged strings with contiguous UTF-8
    /// are read in place; others are copied into scratch space (truncated at 1 KB on a character
    /// boundary). Neither path allocates.
    func withUTF8(of string: String, _ body: (UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
        if let status = string.utf8.withContiguousStorageIfAvailable({ body($0.baseAddress, $0.count) }) {
            return status
        }
        var n = 0
        var boundary = 0
        for byte in string.utf8 {
            if n == scratch.count { break }
            if byte & 0xC0 != 0x80 { boundary = n }
            scratch[n] = byte
            n += 1
        }
        if n == scratch.count { n = boundary }
        return body(UnsafePointer(scratch.baseAddress), n)
    }

    /// Records the hit count a query returned.
    func setCount(_ status: Int32) throws(CoreError) -> Int {
        count = Int(try CoreError.check(status))
        return count
    }

    /// The highlight ranges a ranges call wrote.
    func highlightRanges(_ status: Int32) throws(CoreError) -> [HighlightRange] {
        let n = Int(try CoreError.check(status))
        return (0..<n).map { HighlightRange(location: Int(ranges[$0].start), length: Int(ranges[$0].length)) }
    }
}
