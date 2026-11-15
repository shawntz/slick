import SlickCoreC

/// Copies the ranges a C ranges call wrote into a caller's array, replacing its contents and
/// keeping its capacity, so a warm array takes no allocation.
enum RangeCopy {
    static func replace(
        _ out: inout [HighlightRange], from source: UnsafeMutableBufferPointer<SlickRange>, status: Int32
    ) throws(CoreError) -> Int {
        let n = min(Int(try CoreError.check(status)), source.count)
        out.removeAll(keepingCapacity: true)
        var i = 0
        while i < n {
            out.append(HighlightRange(location: Int(source[i].start), length: Int(source[i].length)))
            i += 1
        }
        return n
    }

    static func replace(
        _ out: inout [Range<Int>], from source: UnsafeMutableBufferPointer<SlickRange>, status: Int32
    ) throws(CoreError) -> Int {
        let n = min(Int(try CoreError.check(status)), source.count)
        out.removeAll(keepingCapacity: true)
        var i = 0
        while i < n {
            let start = Int(source[i].start)
            out.append(start..<(start + Int(source[i].length)))
            i += 1
        }
        return n
    }
}

extension Engine {
    /// Writes the highlight ranges of `key`'s title for the buffer's last query into `ranges`,
    /// replacing its contents and keeping its capacity, and returns how many there are. Reuse one
    /// array across rows and the call allocates nothing.
    @discardableResult
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer, into ranges: inout [HighlightRange])
        throws(CoreError) -> Int
    {
        let status = slick_engine_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try RangeCopy.replace(&ranges, from: buffer.ranges, status: status)
    }

    /// The same as ranges of UTF-16 offsets, the shape a `Row` keeps.
    @discardableResult
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer, into ranges: inout [Range<Int>])
        throws(CoreError) -> Int
    {
        let status = slick_engine_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try RangeCopy.replace(&ranges, from: buffer.ranges, status: status)
    }
}

extension FuzzyIndex {
    /// Writes the highlight ranges of `key`'s title for the buffer's last query into `ranges`,
    /// replacing its contents and keeping its capacity, and returns how many there are.
    @discardableResult
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer, into ranges: inout [HighlightRange])
        throws(CoreError) -> Int
    {
        let status = slick_index_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try RangeCopy.replace(&ranges, from: buffer.ranges, status: status)
    }

    /// The same as ranges of UTF-16 offsets.
    @discardableResult
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer, into ranges: inout [Range<Int>])
        throws(CoreError) -> Int
    {
        let status = slick_index_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try RangeCopy.replace(&ranges, from: buffer.ranges, status: status)
    }
}
