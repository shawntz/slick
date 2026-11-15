import SlickCoreC

/// The root search engine: the catalog, ranking, learning, suggestions and persistence.
///
/// Safe to use from any thread. The Rust side keeps its state behind a reader-writer lock, so
/// queries run concurrently and catalog, context and learning changes take the lock briefly. The
/// class is checked `Sendable`: its one stored handle is `nonisolated(unsafe)` on the strength of
/// that lock, and the compiler still rejects any other non-Sendable stored property.
public final class Engine: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer

    /// Opens an engine. With a `directory` it persists its learning there (created when missing);
    /// without one it keeps everything in memory. Checks the ABI version first. Throws `.io` when
    /// the directory cannot be used, including when another open engine owns it.
    public init(directory: String? = nil) throws(CoreError) {
        try RustCore.checkABI()
        var dir = directory ?? ""
        var opened: OpaquePointer?
        let status = dir.withUTF8 { slick_engine_open($0.baseAddress, $0.count, &opened) }
        try CoreError.check(status)
        guard let opened else { throw .nullPointer }
        handle = opened
    }

    deinit {
        slick_engine_close(handle)
    }

    // MARK: Catalog

    /// Replaces every item of `source` (an id the caller picks per source, such as apps or commands).
    public func replaceSource(_ source: UInt32, with items: [CatalogItem]) throws(CoreError) {
        let packed = try PackedItems(items)
        try CoreError.check(
            packed.withPointers { i, n, s, len in slick_engine_replace_source(handle, source, i, n, s, len) })
    }

    /// Adds or replaces one item of `source`.
    public func upsert(_ item: CatalogItem, source: UInt32) throws(CoreError) {
        let packed = try PackedItems([item])
        try CoreError.check(packed.withPointers { i, _, s, len in slick_engine_upsert(handle, source, i, s, len) })
    }

    /// Removes an item from the catalog. Its learning is kept.
    public func remove(_ key: ItemKey) throws(CoreError) {
        try CoreError.check(slick_engine_remove(handle, key.rawValue))
    }

    /// Number of items in the catalog.
    public func count() throws(CoreError) -> Int {
        Int(try CoreError.check(slick_engine_count(handle)))
    }

    /// Sets the user alias of `key`; an empty alias removes it. Not persisted by the engine.
    public func setAlias(_ alias: String, for key: ItemKey) throws(CoreError) {
        var alias = alias
        try CoreError.check(alias.withUTF8 { slick_engine_set_alias(handle, key.rawValue, $0.baseAddress, $0.count) })
    }

    // MARK: Context and queries

    /// Sets the context and recomputes the suggestions.
    public func setContext(_ context: EngineContext) throws(CoreError) {
        var raw = context.raw
        try CoreError.check(slick_engine_set_context(handle, &raw))
    }

    /// Ranks the catalog for `text` into `buffer` and returns the number of hits. Allocates
    /// nothing, including the String to UTF-8 step.
    @discardableResult
    public func query(_ text: String, into buffer: QueryBuffer) throws(CoreError) -> Int {
        let status = buffer.withUTF8(of: text) { q, n in
            slick_engine_query(handle, buffer.session, q, n, buffer.hits.baseAddress, buffer.capacity)
        }
        return try buffer.setCount(status)
    }

    /// Highlight ranges of `key`'s title for the buffer's last query, in UTF-16 units. Ask only
    /// for visible rows.
    public func highlightRanges(for key: ItemKey, in buffer: QueryBuffer) throws(CoreError) -> [HighlightRange] {
        let status = slick_engine_ranges(
            handle, buffer.session, key.rawValue, buffer.ranges.baseAddress, buffer.ranges.count)
        return try buffer.highlightRanges(status)
    }

    /// The inline completion for the buffer's top hit: the item and the text to show after what
    /// was typed. Nil unless the top hit is decisive and its text starts with the query, and nil
    /// when the rest of the text is longer than the buffer's 1 KB, which no field shows anyway.
    public func completion(in buffer: QueryBuffer) throws(CoreError) -> (key: ItemKey, text: String)? {
        var key: UInt64 = 0
        let status = slick_engine_completion(handle, buffer.session, &key, buffer.text.baseAddress, buffer.text.count)
        if status == SLICK_STATUS_BUFFER_TOO_SMALL.rawValue { return nil }
        let n = Int(try CoreError.check(status))
        guard n > 0 else { return nil }
        return (
            ItemKey(rawValue: key), String(decoding: UnsafeBufferPointer(rebasing: buffer.text[..<n]), as: UTF8.self)
        )
    }

    /// The zero-query suggestions for the current context, best first, at most `limit`.
    public func suggestions(limit: Int = 8) throws(CoreError) -> [Suggestion] {
        guard limit > 0 else { return [] }
        var raw = [SlickSuggestion](repeating: SlickSuggestion(), count: limit)
        let n = Int(
            try CoreError.check(
                raw.withUnsafeMutableBufferPointer { slick_engine_suggestions(handle, $0.baseAddress, $0.count) }))
        return raw.prefix(n).map { Suggestion(key: ItemKey(rawValue: $0.key), score: $0.score) }
    }

    // MARK: Learning

    /// Learns that `key` ran after `query` was typed. Returns false when nothing was learned
    /// (learning is paused or the item opts out). The log write happens off this thread.
    @discardableResult
    public func recordExecution(
        of key: ItemKey,
        query: String,
        source: ExecutionSource,
        rank: Int? = nil,
        at now: Double
    ) throws(CoreError) -> Bool {
        var query = query
        let row = UInt8(clamping: rank ?? 255)
        let status = query.withUTF8 {
            slick_engine_record(handle, key.rawValue, $0.baseAddress, $0.count, source.rawValue, row, now)
        }
        return try CoreError.check(status) == 1
    }

    /// Removes the learning of the last execution when it was `key` and ran at most five seconds
    /// before `now`. Returns whether anything was undone.
    @discardableResult
    public func undoExecution(of key: ItemKey, at now: Double) throws(CoreError) -> Bool {
        try CoreError.check(slick_engine_undo(handle, key.rawValue, now)) == 1
    }

    /// Forgets everything learned about `key`.
    public func forget(_ key: ItemKey) throws(CoreError) {
        try CoreError.check(slick_engine_forget(handle, key.rawValue))
    }

    /// Forgets the learned row of one query, so typing it ranks by text again. The engine folds
    /// `query` the way it folds typed text. Shorter queries it extends keep their own learning.
    /// Returns whether the query had a row. For the learning inspector.
    @discardableResult
    public func forgetQuery(_ query: String) throws(CoreError) -> Bool {
        var query = query
        let status = query.withUTF8 { slick_engine_forget_query(handle, $0.baseAddress, $0.count) }
        return try CoreError.check(status) == 1
    }

    /// A first-run seed: a light virtual use of `key` at Unix time `at`.
    public func seed(_ key: ItemKey, weight: Float, at: Double) throws(CoreError) {
        try CoreError.check(slick_engine_seed(handle, key.rawValue, weight, at))
    }

    /// Pauses or resumes learning.
    public func setLearningPaused(_ paused: Bool) throws(CoreError) {
        try CoreError.check(slick_engine_set_learning_paused(handle, paused))
    }

    /// Erases all learning, in memory and on disk.
    public func resetLearning() throws(CoreError) {
        try CoreError.check(slick_engine_reset_learning(handle))
    }

    /// Waits until every log record so far is on disk.
    public func flush() throws(CoreError) {
        try CoreError.check(slick_engine_flush(handle))
    }

    /// The headline numbers of the learning inspector. Much cheaper than `statisticsJSON()`.
    public func summary() throws(CoreError) -> EngineSummary {
        var raw = SlickLearningSummary()
        try CoreError.check(slick_engine_summary(handle, &raw))
        return EngineSummary(raw)
    }

    /// Learning statistics as JSON for the settings inspector.
    public func statisticsJSON() throws(CoreError) -> String {
        var needed = 0
        var capacity = 16 * 1024
        while true {
            var bytes = [UInt8](repeating: 0, count: capacity)
            let status = bytes.withUnsafeMutableBufferPointer {
                slick_engine_stats(handle, $0.baseAddress, $0.count, &needed)
            }
            if status == SLICK_STATUS_BUFFER_TOO_SMALL.rawValue && needed > capacity {
                capacity = needed
                continue
            }
            try CoreError.check(status)
            return String(decoding: bytes.prefix(needed), as: UTF8.self)
        }
    }
}

/// The headline numbers of the learning inspector.
public struct EngineSummary: Hashable, Sendable {
    /// Executions learned, undone ones excluded.
    public let events: Int
    /// Items with at least one learned execution that were not forgotten since.
    public let items: Int
    /// Learned queries the statistics name.
    public let queries: Int
    /// Unix time of the oldest learned execution of those items, in seconds. Nil when none.
    public let firstEvent: Double?

    init(_ s: SlickLearningSummary) {
        events = Int(clamping: s.events)
        items = Int(clamping: s.items)
        queries = Int(clamping: s.queries)
        firstEvent = s.first_event.isNaN ? nil : s.first_event
    }
}
