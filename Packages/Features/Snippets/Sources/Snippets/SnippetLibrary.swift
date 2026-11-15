import Foundation
import Kit
import KitStorage
import os

/// The user's snippets: kept in memory, saved to one JSON file after each change, and read again
/// when the file changes on disk, such as after an edit by hand.
///
/// Loads, reloads and changes run one at a time in the order they were asked for, so a reload never
/// lands in the middle of a save. While the file cannot be read, nothing is saved, so a file the
/// user is fixing by hand is never overwritten.
final class SnippetLibrary {
    enum State: Hashable {
        case loading
        case ready
        /// The file exists but could not be read. Carries the reason for the log.
        case unreadable(String)
        /// The file was written by a newer version of the app. Its snippets are used, but nothing
        /// is saved, so fields this version does not know are never lost.
        case newerVersion
    }

    static let fileName = "snippets.json"

    /// The snippets as of the last load or change.
    private(set) var index = LibraryIndex.empty
    private(set) var state = State.loading
    /// Sent after the snippets change. The list and root search reload on it.
    let changes = ChangeSignal()
    /// Called with the new index after each change, before ``changes`` is sent. The change is not
    /// finished until it returns, so expansion never lags a save.
    var onChange: (@MainActor (LibraryIndex) async -> Void)?
    /// Called when ``state`` changes.
    var onStateChange: (@MainActor () -> Void)?

    let fileURL: URL
    private let store: JSONFileStore<SnippetFile>
    private let clock: any ClockService
    private let log: Logger
    private var tail: Task<Void, Never>?
    private var firstLoad: Task<Void, Never>?

    /// Does no I/O: the store only holds the path.
    init(context: FeatureContext) {
        fileURL = context.storage.dataFile(Self.fileName)
        store = JSONFileStore(url: fileURL)
        clock = context.clock
        log = context.log
    }

    // MARK: Loading

    /// Reads the file, or saves the starter snippets when there is no file yet. Runs once; later
    /// calls return the same task.
    @discardableResult
    func load() -> Task<Void, Never> {
        if let firstLoad { return firstLoad }
        let task = Task { await self.serially { await self.read(seedingIfMissing: true) } }
        firstLoad = task
        return task
    }

    /// Reads the file when the feature is switched on: the first load, or a reload on a later
    /// activation, because nothing watched the file while the feature was off.
    func refresh() async {
        if firstLoad == nil {
            await load().value
        } else {
            await reload()
        }
    }

    /// Waits for the first load. Pages and root search call it before they read ``index``.
    func ready() async {
        await firstLoad?.value
    }

    /// Reads the file again after it changed on disk. Sends ``changes`` only when the snippets
    /// differ, so the library's own saves cost one read and nothing else.
    func reload() async {
        await serially { await self.read(seedingIfMissing: false) }
    }

    /// Reloads whenever something in the snippets folder changes, until the task is cancelled.
    func watch(with watcher: any FileWatchService) -> Task<Void, Never> {
        // Subscribe before the task starts, so a change in between is not lost.
        let changes = watcher.watch([fileURL.deletingLastPathComponent()])
        return Task { [weak self] in
            for await _ in changes {
                await self?.reload()
            }
        }
    }

    private func read(seedingIfMissing: Bool) async {
        do {
            if let file = try await store.load() {
                setState(file.version > SnippetFile.currentVersion ? .newerVersion : .ready)
                if !Self.sameContent(file.snippets, index.snippets) { await apply(file.snippets) }
            } else if seedingIfMissing {
                let starters = StarterSnippets.all(at: clock.now)
                do {
                    try await store.save(SnippetFile(snippets: starters))
                } catch {
                    log.error("Could not save the starter snippets: \(String(describing: error), privacy: .public)")
                }
                setState(.ready)
                await apply(starters)
            } else {
                // The file was deleted. The next change writes a new one.
                setState(.ready)
                if !index.isEmpty { await apply([]) }
            }
        } catch {
            log.error("Could not read the snippets file: \(String(describing: error), privacy: .private)")
            setState(.unreadable(String(describing: error)))
        }
    }

    // MARK: Changes

    /// Adds a snippet made from the draft and returns it.
    @discardableResult
    func add(_ draft: SnippetDraft) async throws -> Snippet {
        try await serially {
            try self.requireWritable()
            let now = self.clock.now
            let snippet = Snippet(
                id: UUID().uuidString, name: draft.cleanName, text: draft.text, keyword: draft.cleanKeyword,
                collection: draft.cleanCollection, expands: draft.expands, created: now, modified: now)
            try await self.commit(self.index.snippets + [snippet])
            return snippet
        }
    }

    /// Replaces a snippet's fields with the draft's. Throws when the snippet is gone.
    func update(id: String, with draft: SnippetDraft) async throws {
        try await change(id: id) { snippet, now in
            snippet.name = draft.cleanName
            snippet.text = draft.text
            snippet.keyword = draft.cleanKeyword
            snippet.collection = draft.cleanCollection
            snippet.expands = draft.expands
            snippet.modified = now
        }
    }

    func setPinned(_ isPinned: Bool, id: String) async throws {
        try await change(id: id) { snippet, _ in snippet.isPinned = isPinned }
    }

    /// Deletes a snippet. Throws when it is already gone.
    func remove(id: String) async throws {
        try await serially {
            try self.requireWritable()
            guard self.index.snippet(id: id) != nil else { throw ActionFailure(Strings.snippetGone) }
            try await self.commit(self.index.snippets.filter { $0.id != id })
        }
    }

    /// Adds imported entries, decided against the snippets as they are when the import runs.
    func importEntries(_ entries: [TransferEntry], rules: SnippetValidation.Rules) async throws -> ImportSummary {
        try await serially {
            try self.requireWritable()
            let now = self.clock.now
            let merge = SnippetImport.merge(entries, into: self.index.snippets, at: now, rules: rules)
            if merge.summary.added > 0 { try await self.commit(merge.snippets) }
            return merge.summary
        }
    }

    private func change(id: String, _ edit: @escaping @MainActor @Sendable (inout Snippet, Date) -> Void)
        async throws
    {
        try await serially {
            try self.requireWritable()
            let now = self.clock.now
            var found = false
            let updated = self.index.snippets.map { snippet in
                guard snippet.id == id else { return snippet }
                found = true
                var changed = snippet
                edit(&changed, now)
                return changed
            }
            guard found else { throw ActionFailure(Strings.snippetGone) }
            try await self.commit(updated)
        }
    }

    private func requireWritable() throws {
        switch state {
        case .ready: return
        case .newerVersion: throw ActionFailure(Strings.readOnlyTitle, message: Strings.newerFileReadOnlyMessage)
        case .loading, .unreadable: throw ActionFailure(Strings.readOnlyTitle, message: Strings.readOnlyMessage)
        }
    }

    private func commit(_ snippets: [Snippet]) async throws {
        try await store.save(SnippetFile(snippets: snippets))
        await apply(snippets)
    }

    private func apply(_ snippets: [Snippet]) async {
        let built = await LibraryIndex.build(snippets)
        index = built
        await onChange?(built)
        changes.send()
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?()
    }

    // MARK: Ordering

    /// Runs the work after every earlier load and change has finished.
    private func serially<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func serially(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    // MARK: Dates

    /// True when two lists hold the same snippets. The file keeps dates to the millisecond, so dates
    /// less than a millisecond apart count as equal.
    static func sameContent(_ left: [Snippet], _ right: [Snippet]) -> Bool {
        guard left.count == right.count else { return false }
        func same(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case (let lhs?, let rhs?): abs(lhs.timeIntervalSince(rhs)) < 0.001
            default: false
            }
        }
        return zip(left, right).allSatisfy { lhs, rhs in
            guard same(lhs.created, rhs.created), same(lhs.modified, rhs.modified) else { return false }
            var lhs = lhs
            var rhs = rhs
            (lhs.created, lhs.modified, rhs.created, rhs.modified) = (nil, nil, nil, nil)
            return lhs == rhs
        }
    }
}
