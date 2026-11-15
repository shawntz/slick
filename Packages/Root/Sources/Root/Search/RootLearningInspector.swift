import CoreBridge
import Foundation
import Kit
import KitHosting

/// The ``LearningInspector`` over root search's engine and memory. Give ``RootSearch/inspector`` to
/// SettingsUI.
///
/// Counts and learned queries come from the engine's statistics, read and decoded on the engine's
/// queue. Items and their use counts come from root search's usage records. Forget and erase reach
/// the engine, the usage records, the remembered rows and the triggers' learning. Suggestion
/// triggers and their reset come from root search's trigger learning.
public final class RootLearningInspector: LearningInspector {
    public let changes = ChangeSignal()
    private weak var root: RootSearch?

    init(root: RootSearch) {
        self.root = root
    }

    public var isPaused: Bool {
        root?.hostSettings[HostSettings.learningPaused] ?? false
    }

    public func setPaused(_ paused: Bool) {
        guard let root, root.hostSettings[HostSettings.learningPaused] != paused else { return }
        root.hostSettings[HostSettings.learningPaused] = paused
        changes.send()
    }

    /// Runs are the engine's learned events. Items are the distinct items with a recorded use, the
    /// first event is the first run recorded since the last erase, and the size counts the engine's
    /// folder and root search's own files.
    public func summary() async -> LearningSummary {
        guard let root else { return .empty }
        let statistics = await root.engineStatistics()
        let paths = root.configuration.storage
        let engineFolder = root.configuration.environment == .live ? paths.engineDirectory : nil
        let bytes = await Self.bytesOnDisk(
            folder: engineFolder, files: [paths.rememberedFile, paths.usageFile, paths.learningFile])
        return LearningSummary(
            eventCount: statistics?.counts.events ?? 0, itemCount: root.memory.itemCount,
            queryCount: statistics?.affinity.count ?? 0, firstEvent: root.learning.read(\.firstEvent),
            bytesOnDisk: bytes)
    }

    public func topItems(limit: Int) async -> [LearnedItem] {
        guard let root, limit > 0 else { return [] }
        let uses = root.memory.allUses().sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            if left.lastUsed != right.lastUsed { return left.lastUsed > right.lastUsed }
            return left.id.rawValue < right.id.rawValue
        }
        return uses.prefix(limit).map { use in
            let shown = root.display(use.id, snapshot: use.snapshot)
            return LearnedItem(
                id: use.id, title: shown.title, icon: shown.icon, useCount: use.count, lastUsed: use.lastUsed)
        }
    }

    /// Queries come folded, as the engine keeps them. Items the catalog and the usage records no
    /// longer know are left out, because nothing could forget them by ID. The item the engine names
    /// as the row's band holder is marked with ``LearnedQuery/Favored/holdsBand``.
    public func queries(matching text: String, limit: Int) async -> [LearnedQuery] {
        guard let root, limit > 0, let statistics = await root.engineStatistics() else { return [] }
        let needle = text.trimmingCharacters(in: .whitespaces)
        var found: [(query: LearnedQuery, strongest: Double)] = []
        let known = root.knownItemsByKey()
        for row in statistics.affinity {
            guard
                needle.isEmpty
                    || row.query.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }
            var items: [LearnedQuery.Favored] = []
            for item in row.items {
                guard let key = UInt64(item.key), let id = known[key] else { continue }
                let shown = root.display(id, snapshot: nil, engineTitle: item.title)
                items.append(
                    LearnedQuery.Favored(
                        id: id, title: shown.title, icon: shown.icon, weight: item.weight ?? 0,
                        holdsBand: row.band == item.key))
            }
            guard !items.isEmpty else { continue }
            items.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id.rawValue < $1.id.rawValue }
            found.append((LearnedQuery(query: row.query, items: Array(items.prefix(8))), items[0].weight))
        }
        found.sort { $0.strongest != $1.strongest ? $0.strongest > $1.strongest : $0.query.query < $1.query.query }
        return found.prefix(limit).map(\.query)
    }

    public func forget(item id: ItemID) async {
        guard let root else { return }
        await root.forgetAndWait(id)
        changes.send()
    }

    public func forget(query: String) async {
        guard let root else { return }
        _ = await root.forgetQuery(query)
    }

    public func eraseAll() async throws {
        guard let root else { return }
        try await root.eraseLearning()
        changes.send()
    }

    /// The triggers of the features that are on, in directory order, with what was learned about
    /// each.
    public func triggers() async -> [LearnedTrigger] {
        guard let root else { return [] }
        return root.triggerStates.map { state in
            LearnedTrigger(
                featureID: state.featureID, triggerID: state.triggerID, acceptance: state.acceptance,
                impressions: state.impressions, taken: state.taken, isOff: state.isOff)
        }
    }

    /// Switches the trigger back on from its prior and asks it for suggestions again. Sends
    /// ``changes``.
    public func resetTrigger(featureID: String, triggerID: String) async {
        guard let root else { return }
        root.resetTrigger(featureID: featureID, triggerID: triggerID)
        await root.learning.drain()
    }

    @concurrent nonisolated static func bytesOnDisk(folder: URL?, files: [URL?]) async -> Int64 {
        JSONFiles.bytes(inFolder: folder, files: files)
    }
}

extension RootSearch {
    /// The title and icon to show for an item: from the catalog, a remembered row, a usage snapshot
    /// or the engine's title, in that order. The raw ID when none knows it.
    func display(_ id: ItemID, snapshot: Row?, engineTitle: String? = nil) -> (title: String, icon: Icon?) {
        if let row = table.entry(for: id)?.row ?? memory.rememberedRow(id) ?? snapshot {
            return (row.title, row.icon)
        }
        return (engineTitle ?? id.rawValue, nil)
    }

    /// Every item root search can name by its engine key: the catalog and the recorded uses.
    func knownItemsByKey() -> [UInt64: ItemID] {
        var known: [UInt64: ItemID] = [:]
        for use in memory.allUses() {
            known[use.id.engineKey] = use.id
        }
        for (key, entry) in table.entries {
            known[key] = entry.row.id
        }
        return known
    }

    /// Forgets an item and returns once the engine forgot it.
    func forgetAndWait(_ id: ItemID) async {
        forget(id)
        await worker.drain()
        await memory.drain()
    }

    /// Forgets one learned query in the engine, so typing it ranks by text again. True when the
    /// query had something learned.
    func forgetQuery(_ query: String) async -> Bool {
        guard !isShutDown else { return false }
        let forgotten = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            worker.perform { engine in
                continuation.resume(returning: EngineCalls.forgetQuery(query, in: engine))
            }
        }
        if forgotten { inspector.changes.send() }
        return forgotten
    }

    /// Erases everything learned: the engine's log and snapshot, the usage records, the remembered
    /// rows, the first event and the triggers' learning. Seeding does not run again. Throws, and
    /// erases nothing, when the engine cannot reset.
    func eraseLearning() async throws {
        guard !isShutDown else { return }
        let failure = await withCheckedContinuation { (continuation: CheckedContinuation<CoreError?, Never>) in
            worker.perform { engine in
                do throws(CoreError) {
                    try engine?.resetLearning()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
        if let failure { throw failure }
        memory.eraseAll()
        learning.update { state in
            state.firstEvent = nil
            state.triggers = [:]
            state.ignored = [:]
        }
        triggerDraws.removeAll()
        drawsStale = true
        lastRun = nil
        scheduleRebuild()
        refreshContext()
        await memory.drain()
        await learning.drain()
    }
}

/// Engine calls the learning inspector makes on the engine's queue.
nonisolated enum EngineCalls {
    /// Forgets one learned query. True when the engine had learned something for it.
    static func forgetQuery(_ query: String, in engine: Engine?) -> Bool {
        guard let engine else { return false }
        return (try? engine.forgetQuery(query)) ?? false
    }
}
