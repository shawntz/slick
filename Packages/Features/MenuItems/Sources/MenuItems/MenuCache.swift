import Kit

/// The menus read in this session, one entry per app, so the next search of the same app shows at
/// once while a fresh read runs. It lives in memory only and is emptied when the feature turns off.
final class MenuCache {
    /// One app's menus and their search index.
    struct Entry {
        let snapshot: MenuSnapshot
        /// Built off the main thread. A search awaits it; the first page does not need it.
        let index: Task<any FuzzyIndex, Never>
        /// Tells this entry from the one it replaced.
        let generation: Int
    }

    /// Apps kept at most. The one used longest ago goes first.
    static let capacity = 8

    private var entries: [String: Entry] = [:]
    /// Bundle IDs, the one used most recently last.
    private var order: [String] = []
    private var nextGeneration = 0

    var count: Int { entries.count }

    /// The entry for an app, which becomes the most recently used.
    func entry(for bundleID: String) -> Entry? {
        guard let entry = entries[bundleID] else { return nil }
        touch(bundleID)
        return entry
    }

    /// Keeps a snapshot, unless it would replace a complete one with a partial one, or the caller
    /// found it equal to the entry of `unchangedSince`, comparing off the main thread. Returns true
    /// when what the app's list shows changed.
    @discardableResult
    func store(_ snapshot: MenuSnapshot, fuzzy: any FuzzyIndexService, unchangedSince generation: Int? = nil) -> Bool {
        let bundleID = snapshot.app.bundleID
        // A read that stopped before it found anything has nothing worth showing.
        if !snapshot.isComplete && snapshot.items.isEmpty { return false }
        if let existing = entries[bundleID] {
            if existing.snapshot.isComplete && !snapshot.isComplete { return false }
            if let generation, generation == existing.generation {
                touch(bundleID)
                return false
            }
        }
        nextGeneration += 1
        let index = Task { await fuzzy.makeIndex(await Self.buildEntries(snapshot)) }
        entries[bundleID] = Entry(snapshot: snapshot, index: index, generation: nextGeneration)
        touch(bundleID)
        while order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return true
    }

    func remove(_ bundleID: String) {
        entries.removeValue(forKey: bundleID)
        order.removeAll { $0 == bundleID }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func touch(_ bundleID: String) {
        order.removeAll { $0 == bundleID }
        order.append(bundleID)
    }

    @concurrent private nonisolated static func buildEntries(_ snapshot: MenuSnapshot) async -> [FuzzyEntry] {
        MenuRows.entries(snapshot)
    }
}
