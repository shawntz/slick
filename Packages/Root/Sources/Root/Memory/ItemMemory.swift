import Foundation
import Kit
import Synchronization
import os

/// What root search keeps about items between launches: uses for ``UsageService`` and the rows the
/// user ran that came from live providers or suggestions.
///
/// Reads and writes are in-memory and safe from any thread. Every change queues one save on a
/// utility queue, which writes JSON files atomically with owner-only permissions. Saves that pile
/// up while one is waiting collapse into it.
nonisolated final class ItemMemory: Sendable {
    /// One item's recorded uses.
    struct Use: Codable, Sendable {
        var id: ItemID
        /// The row as last recorded, when its memory allowed a snapshot.
        var snapshot: Row?
        var lastUsed: Date
        var count: Int
        /// The frecency at ``lastUsed``: each use adds 1, and the sum halves every 7 days.
        var score: Double
    }

    /// A remembered row and when it last ran.
    struct Remembered: Codable, Sendable {
        var row: Row
        var lastUsed: Date
    }

    /// The most uses kept. The least recently used go first.
    static let maxUses = 10_000
    /// The most remembered rows kept. The least recently run go first.
    static let maxRemembered = 2_000
    /// Frecency halves over this many seconds, as ``UsageService/frecency(namespace:)`` documents.
    static let halfLife: TimeInterval = 7 * 86_400

    private struct Files: OptionSet {
        let rawValue: Int
        static let usage = Files(rawValue: 1)
        static let remembered = Files(rawValue: 2)
    }

    private struct State {
        var uses: [String: [ItemID: Use]] = [:]
        var useCount = 0
        var remembered: [ItemID: Remembered] = [:]
        var dirty: Files = []
        var saveQueued = false

        /// Marks files to save. True when the caller must queue the save.
        mutating func markDirty(_ files: Files) -> Bool {
            dirty.formUnion(files)
            guard !saveQueued else { return false }
            saveQueued = true
            return true
        }
    }

    private let state = Mutex(State())
    private let io = DispatchQueue(label: "root.memory", qos: .utility)
    private let usageFile: URL?
    private let rememberedFile: URL?
    private let log = KitLog.logger(category: "root")

    init(usageFile: URL?, rememberedFile: URL?) {
        self.usageFile = usageFile
        self.rememberedFile = rememberedFile
    }

    // MARK: Uses

    /// Records one use at `date`. A snapshot replaces the previous one.
    func recordUse(of id: ItemID, snapshot: Row?, at date: Date) {
        let namespace = id.namespace
        let queue = state.withLock { state in
            var use = state.uses[namespace]?[id] ?? Use(id: id, snapshot: nil, lastUsed: date, count: 0, score: 0)
            if use.count == 0 { state.useCount += 1 }
            use.score = Self.decayed(use.score, from: use.lastUsed, to: date) + 1
            use.lastUsed = max(use.lastUsed, date)
            use.count += 1
            if let snapshot { use.snapshot = snapshot }
            state.uses[namespace, default: [:]][id] = use
            return state.markDirty(.usage)
        }
        if queue { queueSave() }
    }

    func recentlyUsed(namespace: String, limit: Int) -> [UsageRecord] {
        guard limit > 0 else { return [] }
        let uses = state.withLock { $0.uses[namespace].map { Array($0.values) } ?? [] }
        return uses.sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.id.rawValue < $1.id.rawValue }
            .prefix(limit)
            .map { UsageRecord(id: $0.id, snapshot: $0.snapshot, lastUsed: $0.lastUsed, count: $0.count) }
    }

    func useCount(of id: ItemID) -> Int {
        let namespace = id.namespace
        return state.withLock { $0.uses[namespace]?[id]?.count ?? 0 }
    }

    func frecency(namespace: String, now: Date) -> [ItemID: Double] {
        state.withLock { state in
            (state.uses[namespace] ?? [:]).mapValues { Self.decayed($0.score, from: $0.lastUsed, to: now) }
        }
    }

    /// Every recorded use, in no particular order, for the learning inspector.
    func allUses() -> [UsageRecord] {
        state.withLock { state in
            state.uses.values.flatMap(\.values).map {
                UsageRecord(id: $0.id, snapshot: $0.snapshot, lastUsed: $0.lastUsed, count: $0.count)
            }
        }
    }

    /// How many distinct items have a recorded use.
    var itemCount: Int {
        state.withLock { $0.uses.values.reduce(0) { $0 + $1.count } }
    }

    /// The most recent use of any item, for the context's previous item after a relaunch.
    func lastUse() -> (id: ItemID, at: Date)? {
        state.withLock { state in
            var best: Use?
            for namespace in state.uses.values {
                for use in namespace.values where best.map({ use.lastUsed > $0.lastUsed }) ?? true {
                    best = use
                }
            }
            return best.map { ($0.id, $0.lastUsed) }
        }
    }

    // MARK: Remembered rows

    /// Remembers a row. True when the catalog must be rebuilt: the row is new or shows differently.
    func remember(_ row: Row, at date: Date) -> Bool {
        var stored = row
        stored.titleHighlights = []
        let (changed, queue) = state.withLock { state in
            let changed = state.remembered[row.id].map { $0.row != stored } ?? true
            state.remembered[row.id] = Remembered(row: stored, lastUsed: date)
            return (changed, state.markDirty(.remembered))
        }
        if queue { queueSave() }
        return changed
    }

    func rememberedRow(_ id: ItemID) -> Row? {
        state.withLock { $0.remembered[id]?.row }
    }

    func rememberedRows() -> [Row] {
        state.withLock { $0.remembered.values.map(\.row) }
    }

    func rememberedIDs() -> [ItemID] {
        state.withLock { Array($0.remembered.keys) }
    }

    // MARK: Forgetting

    /// Forgets an item's uses and its remembered row. True when a remembered row went away.
    @discardableResult
    func forget(_ id: ItemID) -> Bool {
        let namespace = id.namespace
        let (removed, queue) = state.withLock { state in
            if state.uses[namespace]?.removeValue(forKey: id) != nil { state.useCount -= 1 }
            let removed = state.remembered.removeValue(forKey: id) != nil
            return (removed, state.markDirty([.usage, .remembered]))
        }
        if queue { queueSave() }
        return removed
    }

    /// Forgets every item in a namespace. True when a remembered row went away.
    @discardableResult
    func forgetAll(namespace: String) -> Bool {
        let (removed, queue) = state.withLock { state in
            state.useCount -= state.uses.removeValue(forKey: namespace)?.count ?? 0
            let before = state.remembered.count
            state.remembered = state.remembered.filter { $0.key.namespace != namespace }
            return (state.remembered.count != before, state.markDirty([.usage, .remembered]))
        }
        if queue { queueSave() }
        return removed
    }

    /// Forgets everything.
    func eraseAll() {
        let queue = state.withLock { state in
            state.uses = [:]
            state.useCount = 0
            state.remembered = [:]
            return state.markDirty([.usage, .remembered])
        }
        if queue { queueSave() }
    }

    // MARK: Files

    /// Reads both files and merges them into what was recorded since launch.
    func load() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            io.async {
                self.loadNow()
                continuation.resume()
            }
        }
    }

    /// Returns once every save queued so far is written.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            io.async { continuation.resume() }
        }
    }

    private func loadNow() {
        let uses: [Use] = read(usageFile)
        let remembered: [Remembered] = read(rememberedFile)
        state.withLock { state in
            for loaded in uses {
                let namespace = loaded.id.namespace
                guard var use = state.uses[namespace]?[loaded.id] else {
                    state.uses[namespace, default: [:]][loaded.id] = loaded
                    state.useCount += 1
                    continue
                }
                let latest = max(use.lastUsed, loaded.lastUsed)
                use.score =
                    Self.decayed(use.score, from: use.lastUsed, to: latest)
                    + Self.decayed(loaded.score, from: loaded.lastUsed, to: latest)
                use.count += loaded.count
                use.lastUsed = latest
                use.snapshot = use.snapshot ?? loaded.snapshot
                state.uses[namespace]?[loaded.id] = use
            }
            for loaded in remembered where state.remembered[loaded.row.id] == nil {
                state.remembered[loaded.row.id] = loaded
            }
        }
    }

    private func queueSave() {
        io.async { self.save() }
    }

    /// Writes the files marked dirty, after trimming to the limits.
    private func save() {
        let (files, uses, remembered) = state.withLock { state -> (Files, [Use], [Remembered]) in
            defer {
                state.dirty = []
                state.saveQueued = false
            }
            Self.trim(&state)
            let uses = state.dirty.contains(.usage) ? state.uses.values.flatMap(\.values) : []
            let remembered = state.dirty.contains(.remembered) ? Array(state.remembered.values) : []
            return (state.dirty, uses, remembered)
        }
        if files.contains(.usage), let usageFile {
            write(uses.sorted { $0.lastUsed > $1.lastUsed }, to: usageFile)
        }
        if files.contains(.remembered), let rememberedFile {
            write(remembered.sorted { $0.lastUsed > $1.lastUsed }, to: rememberedFile)
        }
    }

    private static func trim(_ state: inout State) {
        if state.useCount > maxUses {
            let all = state.uses.values.flatMap(\.values).sorted { $0.lastUsed > $1.lastUsed }
            for use in all.dropFirst(maxUses * 9 / 10) {
                state.uses[use.id.namespace]?.removeValue(forKey: use.id)
            }
            state.useCount = state.uses.values.reduce(0) { $0 + $1.count }
            state.dirty.insert(.usage)
        }
        if state.remembered.count > maxRemembered {
            let kept = state.remembered.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(maxRemembered * 9 / 10)
            state.remembered = Dictionary(uniqueKeysWithValues: kept.map { ($0.row.id, $0) })
            state.dirty.insert(.remembered)
        }
    }

    /// A score that was `score` at `from`, halved for every half-life until `to`.
    static func decayed(_ score: Double, from: Date, to: Date) -> Double {
        let age = max(0, to.timeIntervalSince(from))
        return score * pow(0.5, age / halfLife)
    }

    // MARK: JSON

    /// A file's elements. One element that does not decode is skipped, not the whole file.
    private func read<Element: Decodable>(_ url: URL?) -> [Element] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode(StoredFile<Element>.self, from: data).items.compactMap(\.value)
        } catch {
            log.error("root search could not read \(url.lastPathComponent, privacy: .public): \(error)")
            return []
        }
    }

    /// Writes the elements atomically. One element that does not encode, such as a row whose payload
    /// fails, is left out rather than losing the file.
    private func write<Element: Encodable>(_ elements: [Element], to url: URL) {
        let encoder = JSONEncoder()
        var data = Data(#"{"version":1,"items":["#.utf8)
        var first = true
        for element in elements {
            guard let encoded = try? encoder.encode(element) else { continue }
            if !first { data.append(UInt8(ascii: ",")) }
            data.append(encoded)
            first = false
        }
        data.append(contentsOf: "]}".utf8)
        JSONFiles.write(data, to: url, log: log)
    }
}

/// The JSON layout of both files: a version and the elements.
nonisolated private struct StoredFile<Element: Decodable>: Decodable {
    var version: Int
    var items: [Lossy<Element>]
}

/// An element that decodes to nil instead of failing the array.
nonisolated private struct Lossy<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}
