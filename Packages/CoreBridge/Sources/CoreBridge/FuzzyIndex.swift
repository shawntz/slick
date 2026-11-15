import SlickCoreC

/// A searchable list owned by one feature (clipboard history, snippets, emoji): the matcher and
/// ranking layout of root search without any of its learning.
///
/// Safe to use from any thread; checked `Sendable` for the same reason as `Engine`.
public final class FuzzyIndex: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer

    /// An empty index.
    public init() throws(CoreError) {
        try RustCore.checkABI()
        var created: OpaquePointer?
        try CoreError.check(slick_index_new(&created))
        guard let created else { throw .nullPointer }
        handle = created
    }

    deinit {
        slick_index_free(handle)
    }

    /// Replaces every item. An item's prior lifts it within its tier; kind and flags are ignored.
    public func setItems(_ items: [CatalogItem]) throws(CoreError) {
        let packed = try PackedItems(items)
        try CoreError.check(packed.withPointers { i, n, s, len in slick_index_set_items(handle, i, n, s, len) })
    }

    /// Number of items.
    public func count() throws(CoreError) -> Int {
        Int(try CoreError.check(slick_index_count(handle)))
    }

    /// Ranks the items for `text` into `buffer` and returns the number of hits. Allocates nothing.
    @discardableResult
    public func query(_ text: String, into buffer: QueryBuffer) throws(CoreError) -> Int {
        let status = buffer.withUTF8(of: text) { q, n in
            slick_index_query(handle, buffer.session, q, n, buffer.hits.baseAddress, buffer.capacity)
        }
        return try buffer.setCount(status)
    }

    /// Highlight ranges of `key`'s title for the buffer's last query, in UTF-16 units.
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer) throws(CoreError) -> [HighlightRange] {
        let status = slick_index_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try buffer.highlightRanges(status)
    }
}
