import CoreBridge
import Kit
import Synchronization
import os

/// ``FuzzyIndexService`` over the engine's matcher, so host-filtered lists rank exactly like root
/// search, by the same text tiers and without learning.
nonisolated final class EngineFuzzyIndexService: FuzzyIndexService {
    @concurrent func makeIndex(_ entries: [FuzzyEntry]) async -> any Kit.FuzzyIndex {
        EngineFuzzyIndex(entries)
    }
}

/// One built index. Searching is synchronous and meant for the main thread; a lock guards the
/// reusable query buffer, so a search from another thread waits instead of corrupting it.
nonisolated final class EngineFuzzyIndex: Kit.FuzzyIndex {
    let count: Int
    private let index: CoreBridge.FuzzyIndex?
    private let buffer: Mutex<QueryBuffer?>

    /// Builds the index. An entry's key is its position plus one, so ties fall to the lower index,
    /// as the contract asks.
    init(_ entries: [FuzzyEntry]) {
        count = entries.count
        let items = entries.enumerated().map { position, entry in
            CatalogItem(
                key: ItemKey(rawValue: UInt64(position) + 1), title: CatalogBuilder.clean(entry.title),
                keywords: entry.keywords.map(CatalogBuilder.clean).filter { !$0.isEmpty })
        }
        var built: CoreBridge.FuzzyIndex?
        do throws(CoreError) {
            let index = try CoreBridge.FuzzyIndex()
            try index.setItems(items)
            built = index
        } catch {
            KitLog.logger(category: "root").error("fuzzy index failed: \(error)")
        }
        index = built
        buffer = Mutex(try? QueryBuffer(capacity: 64))
    }

    /// Kit lets a caller pass any limit, and Host passes `Int.max` for "every match", so the limit
    /// is capped at the index size before it sizes the buffer.
    func search(_ query: String, limit: Int) -> [FuzzyMatch] {
        let limit = min(limit, count)
        guard limit > 0, let index else { return [] }
        return buffer.withLock { stored -> [FuzzyMatch] in
            if stored == nil || stored.map({ $0.capacity < limit }) == true {
                stored = try? QueryBuffer(capacity: max(limit, 64))
            }
            guard let buffer = stored, let found = try? index.query(query, into: buffer) else { return [] }
            let n = min(found, limit)
            var matches: [FuzzyMatch] = []
            matches.reserveCapacity(n)
            var i = 0
            while i < n {
                let hit = buffer[i]
                let ranges = (try? index.highlightRanges(for: hit.key, in: buffer)) ?? []
                matches.append(
                    FuzzyMatch(
                        index: Int(hit.key.rawValue - 1), tier: Self.tier(hit.tier), score: Int(hit.rank),
                        highlights: ranges.map { $0.location..<($0.location + $0.length) }))
                i += 1
            }
            return matches
        }
    }

    /// Kit's tier for an engine text tier: 6 exact down to 1 typo and 0 subsequence.
    static func tier(_ engineTier: UInt8) -> MatchTier {
        MatchTier(rawValue: 6 - Int(min(engineTier, 6))) ?? .subsequence
    }
}
