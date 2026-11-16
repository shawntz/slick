import CoreBridge
import Foundation
import Kit
import Synchronization
import os

/// Where the index stands.
nonisolated enum IndexPhase: Hashable, Sendable {
    /// Nothing opened yet, or the feature is off.
    case idle
    /// The first open or walk is running, so there is nothing to search yet.
    case building
    case ready
    /// Opening and walking failed, and there is no index to search.
    case failed
}

/// What the status line, the notice and the pane show about the index.
nonisolated struct IndexSummary: Hashable, Sendable {
    var phase: IndexPhase = .idle
    /// Entries in the current snapshot, files and folders.
    var count = 0
    /// When the index last changed.
    var updatedAt: Date?
    /// A walk runs now: the first build, a rebuild, a catch-up or a change of scope.
    var isWalking = false
    /// The saved index was damaged, so it was walked again.
    var rebuiltAfterDamage = false
    /// Protected places the scope searches whose folders could not be read.
    var unreadable: Set<ProtectedPlace> = []
    /// Protected places the scope searches whose permission went away while the feature ran. Their
    /// events are dropped until the feature follows a new scope.
    var accessLost: Set<ProtectedPlace> = []
}

/// What opening or walking found.
nonisolated struct LoadOutcome: Hashable, Sendable {
    var opening: IndexOpening?
    var unreadable: Set<ProtectedPlace> = []
    var failed = false
    /// The saved index matched the saved mark, so the watch replays what changed while the feature
    /// was off and nothing is walked again.
    var resumed = false
}

/// Owns the index: opens or walks it, applies file events in batches, walks again on request, and
/// saves it at quiet moments and when the feature stops.
///
/// Every call that reads or writes the disk runs on one serial queue at utility priority, never on
/// the main thread. Searches read the current ``index`` from any thread and never wait for this
/// queue: the Rust index publishes immutable snapshots. ``close()`` stops a walk that runs at its
/// next folder, so turning the feature off or quitting never waits for a whole walk.
///
/// Events arrive in batches from Kit's file watcher, with FSEvents' flags and the mark to save.
/// Paths gather while a batch is applied and go in together as the next one. A path the scope does
/// not allow is dropped before it reaches the index, so an event can never make it read a folder
/// macOS guards. An event that asks for a rescan, or an event without flags that names a root,
/// lists that folder again with everything below it.
///
/// The index is saved with the mark of the last batch it holds. The next start passes that mark to
/// the watcher, which replays what changed while the feature was off, so the saved index is not
/// walked again. A batch that failed, or event IDs that wrapped, drop the mark, and the next start
/// walks again. A batch the close stopped keeps the mark from before it, so the next start replays
/// it.
nonisolated final class IndexController: Sendable {
    private struct State {
        var index: FileIndex?
        var plan: ScopePlan?
        var summary = IndexSummary()
        /// Paths waiting to be applied, in order, and the FSEvents flags each gathered.
        var pending: [String] = []
        var pendingFlags: [String: UInt32] = [:]
        /// The mark of the newest batch that waits, applied with the paths before it.
        var pendingMark: FileChangeMark?
        /// The mark of the newest batch the index holds, saved with it.
        var mark: FileChangeMark?
        var drainScheduled = false
        /// Changes not yet saved.
        var dirty = false
        /// Moves on at every close, so work queued by an earlier activation finds nothing to do.
        var generation = 0
        var saveTask: Task<Void, Never>?
    }

    /// FSEvents' `kFSEventStreamEventFlagMustScanSubDirs`.
    static let mustScanSubDirs: UInt32 = 0x0000_0001
    /// The most event paths kept waiting. Paths wait while a walk runs, which can take minutes, and
    /// a busy folder can send many thousands. Past this many, the waiting paths are replaced by the
    /// roots, which lists them all again once the walk ends, as FSEvents asks after it drops events.
    static let pendingLimit = 50_000
    /// How long the index must be still before it is saved.
    static let quietPeriod: Duration = .seconds(30)

    /// The index file in the feature's data folder.
    let file: String
    /// Sent after every published change, including each batch of events.
    let contentChanges = ChangeSignal()
    /// Sent when the summary or the scope changed in a way people see: a walk started or ended,
    /// the scope changed, a folder could not be read.
    let stateChanges = ChangeSignal()

    private let maker: any IndexMaker
    private let clock: any ClockService
    private let log: Logger
    /// Whether the feature may still read a searched place now. Asked before each batch of events,
    /// so a permission taken away while the feature runs stops reads below that place at once.
    private let mayRead: @Sendable (ProtectedPlace) -> Bool
    private let queue = DispatchQueue(label: "files.index", qos: .utility)
    private let state = Mutex(State())
    /// Stops a walk when the feature stops. Nil only when the core could not make one; walks then
    /// run to their end.
    let cancellation = try? FileWalkCancellation()

    init(
        file: String, maker: any IndexMaker, clock: any ClockService, log: Logger,
        mayRead: @escaping @Sendable (ProtectedPlace) -> Bool = { _ in true }
    ) {
        self.file = file
        self.maker = maker
        self.clock = clock
        self.log = log
        self.mayRead = mayRead
    }

    var summary: IndexSummary { state.withLock { $0.summary } }

    /// The index to search, nil until the first open ends.
    var index: FileIndex? { state.withLock { $0.index } }

    /// The scope the index follows now.
    var plan: ScopePlan? { state.withLock { $0.plan } }

    // MARK: - Opening and walking

    /// The mark saved with the index file, read on the index queue. Nil when there is none.
    func savedMark() async -> FileChangeMark? {
        await onQueue { [self] in maker.savedMark(for: file) }
    }

    /// Opens the saved index when it was saved for this scope, and walks the scope otherwise.
    ///
    /// A saved index that is current to `mark`, the mark the watch resumes from, is used as it is:
    /// the watch replays what changed meanwhile. Any other saved index is walked again in the
    /// background, because what changed while the feature was off is unknown.
    @discardableResult
    func load(_ plan: ScopePlan, resuming mark: FileChangeMark? = nil) async -> LoadOutcome {
        let generation = state.withLock { state in
            state.plan = plan
            if state.index == nil { state.summary.phase = .building }
            state.summary.isWalking = true
            return state.generation
        }
        stateChanges.send()
        let outcome = await onQueue { [self] in openNow(plan, generation: generation, resuming: mark) }
        if outcome.opening?.fromFile == true, !outcome.resumed {
            queue.async { [self] in _ = rebuildNow(generation: generation) }
        }
        scheduleDrain()
        return outcome
    }

    /// Follows a new scope. When it changes what the index holds, the scope is walked into a new
    /// index that replaces the old one; searches use the old one until then.
    @discardableResult
    func rescope(_ plan: ScopePlan) async -> LoadOutcome? {
        let (needsWalk, generation) = state.withLock { state in
            let needsWalk = state.plan?.configuration != plan.configuration || state.index == nil
            state.plan = plan
            // The new scope was made from the permissions as they are now.
            state.summary.accessLost = []
            if needsWalk { state.summary.isWalking = true }
            return (needsWalk, state.generation)
        }
        stateChanges.send()
        guard needsWalk else { return nil }
        let outcome = await onQueue { [self] in buildNow(plan, generation: generation) }
        scheduleDrain()
        return outcome
    }

    /// Walks every root again.
    @discardableResult
    func rebuild() async -> LoadOutcome {
        let generation = state.withLock { $0.generation }
        return await onQueue { [self] in rebuildNow(generation: generation) }
    }

    /// Opens or walks, and takes `mark` as the index's own when the opened file is current to it.
    /// That happens here on the queue, before any batch the watch sends can be applied.
    private func openNow(_ plan: ScopePlan, generation: Int, resuming mark: FileChangeMark?) -> LoadOutcome {
        do {
            let (index, opening) = try maker.open(at: file, plan.configuration, cancellation: cancellation)
            let unreadable = Self.unreadablePlaces(in: index, plan: plan)
            guard install(index, generation: generation, unreadable: unreadable, damaged: opening.wasDamaged) else {
                return LoadOutcome(opening: opening)
            }
            var resumed = false
            if let mark, opening.fromFile, opening.eventID != 0, opening.eventID == mark.eventID {
                resumed = state.withLock { state in
                    guard state.generation == generation else { return false }
                    state.mark = mark
                    return true
                }
            }
            if opening.wasDamaged {
                log.notice("The saved file index was damaged and was walked again")
            }
            if !opening.fromFile { saveNow() }
            return LoadOutcome(opening: opening, unreadable: unreadable, resumed: resumed)
        } catch {
            return fail(error, generation: generation)
        }
    }

    private func buildNow(_ plan: ScopePlan, generation: Int) -> LoadOutcome {
        do {
            let index = try maker.build(plan.configuration, cancellation: cancellation)
            let unreadable = Self.unreadablePlaces(in: index, plan: plan)
            guard install(index, generation: generation, unreadable: unreadable, damaged: false) else {
                return LoadOutcome()
            }
            saveNow()
            return LoadOutcome(unreadable: unreadable)
        } catch {
            return fail(error, generation: generation)
        }
    }

    private func rebuildNow(generation: Int) -> LoadOutcome {
        let current = state.withLock { state -> (FileIndex, ScopePlan)? in
            guard state.generation == generation, let index = state.index, let plan = state.plan else { return nil }
            state.summary.isWalking = true
            return (index, plan)
        }
        guard let (index, plan) = current else { return LoadOutcome() }
        stateChanges.send()
        do {
            try maker.rebuild(index, cancellation: cancellation)
            let unreadable = Self.unreadablePlaces(in: index, plan: plan)
            guard install(index, generation: generation, unreadable: unreadable, damaged: false) else {
                return LoadOutcome()
            }
            saveNow()
            return LoadOutcome(unreadable: unreadable)
        } catch {
            return fail(error, generation: generation)
        }
    }

    /// Makes `index` current and publishes its summary. False when the feature stopped meanwhile.
    private func install(_ index: FileIndex, generation: Int, unreadable: Set<ProtectedPlace>, damaged: Bool) -> Bool {
        let count = (try? index.count()) ?? 0
        let now = clock.now
        let installed = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.index = index
            state.dirty = true
            state.summary.phase = .ready
            state.summary.count = count
            state.summary.updatedAt = now
            state.summary.isWalking = false
            state.summary.rebuiltAfterDamage = damaged
            state.summary.unreadable = unreadable
            return true
        }
        guard installed else { return false }
        contentChanges.send()
        stateChanges.send()
        return true
    }

    /// A walk that stopped because the feature stopped is not a failure: nothing changes and
    /// nothing is logged as an error.
    private func fail(_ error: any Error, generation: Int) -> LoadOutcome {
        if (error as? CoreError) == .cancelled {
            log.notice("A walk of the file index stopped because File Search stopped")
            state.withLock { state in
                guard state.generation == generation else { return }
                state.summary.isWalking = false
            }
            stateChanges.send()
            return LoadOutcome()
        }
        log.error("The file index could not be opened or walked: \(String(describing: error), privacy: .public)")
        state.withLock { state in
            guard state.generation == generation else { return }
            state.summary.isWalking = false
            if state.index == nil { state.summary.phase = .failed }
        }
        stateChanges.send()
        return LoadOutcome(failed: true)
    }

    // MARK: - Events

    /// Queues the paths of one batch from the file watcher. Returns at once; the batch is applied
    /// on the index queue together with any that arrive before it starts.
    ///
    /// A path the current scope does not allow, such as one in the home folder's Library, which
    /// changes all the time, is dropped here, so it never waits in memory behind a walk. Its mark
    /// still counts: nothing below it needs applying. A change that only says the replay ended
    /// changes nothing.
    func submit(_ batch: FileChangeBatch) {
        let plan = state.withLock { $0.plan }
        var forgetsMark = false
        var changes: [(String, UInt32)] = []
        for change in batch.events {
            if change.flags.contains(.eventIDsWrapped) { forgetsMark = true }
            if change.flags == .historyDone { continue }
            guard let path = Paths.normalized(change.url.path(percentEncoded: false), home: nil) else { continue }
            if let plan, !plan.allows(path) { continue }
            changes.append((path, Self.eventFlags(change.flags, rescans: plan?.isRoot(path) == true)))
        }
        state.withLock { state in
            for (path, flags) in changes {
                if let gathered = state.pendingFlags[path] {
                    state.pendingFlags[path] = gathered | flags
                } else {
                    state.pending.append(path)
                    state.pendingFlags[path] = flags
                }
            }
            if state.pending.count > Self.pendingLimit, let roots = state.plan?.roots {
                state.pending = roots
                state.pendingFlags = Dictionary(roots.map { ($0, Self.mustScanSubDirs) }, uniquingKeysWith: { $0 | $1 })
            }
            if forgetsMark {
                // Every saved event ID means nothing now. Later batches bring marks on the new count.
                state.mark = nil
                state.pendingMark = nil
                state.dirty = true
            } else if let mark = batch.mark {
                state.pendingMark = mark
            }
        }
        scheduleDrain()
    }

    /// Queues paths without flags, as an action that moved a file does.
    func submit(_ urls: [URL]) {
        submit(FileChangeBatch(urls.map { FileChange($0) }))
    }

    /// FSEvents' flag bits for a change, which the index reads. A change that asks for a rescan, or
    /// one without flags that names a root, lists the folder again with everything below it.
    static func eventFlags(_ flags: FileChangeFlags, rescans isRoot: Bool) -> UInt32 {
        var raw: UInt32 = 0
        let table: [(FileChangeFlags, UInt32)] = [
            (.mustScanSubdirectories, 0x0000_0001), (.userDropped, 0x0000_0002), (.kernelDropped, 0x0000_0004),
            (.eventIDsWrapped, 0x0000_0008), (.historyDone, 0x0000_0010), (.rootChanged, 0x0000_0020),
            (.mount, 0x0000_0040), (.unmount, 0x0000_0080), (.created, 0x0000_0100), (.removed, 0x0000_0200),
            (.metadataModified, 0x0000_0400), (.renamed, 0x0000_0800), (.modified, 0x0000_1000),
            (.isFile, 0x0001_0000), (.isDirectory, 0x0002_0000), (.isSymlink, 0x0004_0000),
        ]
        for (flag, bit) in table where flags.contains(flag) {
            raw |= bit
        }
        if flags.requiresRescan || (flags.isEmpty && isRoot) { raw |= mustScanSubDirs }
        return raw
    }

    /// How many event paths wait to be applied. For tests.
    var pendingCount: Int { state.withLock { $0.pending.count } }

    /// The mark of the newest batch the index holds. For tests.
    var mark: FileChangeMark? { state.withLock { $0.mark } }

    private func scheduleDrain() {
        let schedule = state.withLock { state -> Bool in
            guard !state.drainScheduled, state.index != nil, !state.pending.isEmpty || state.pendingMark != nil
            else { return false }
            state.drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        let (paths, flags, mark, index, plan, generation, unreadable) = state.withLock { state in
            let taken = (state.pending, state.pendingFlags, state.pendingMark)
            state.pending = []
            state.pendingFlags = [:]
            state.pendingMark = nil
            state.drainScheduled = false
            return (taken.0, taken.1, taken.2, state.index, state.plan, state.generation, state.summary.unreadable)
        }
        guard let index, let plan else { return }
        guard !paths.isEmpty else {
            hold(mark, generation: generation)
            return
        }
        // A place whose permission went away since the scope was made: reading below it now could
        // fail or raise a prompt, so its events wait for the feature to follow a new scope.
        let revoked = Set(plan.placeFolders.keys.filter { !mayRead($0) })
        if !revoked.isEmpty {
            let isNew = state.withLock { state -> Bool in
                guard state.generation == generation, !revoked.isSubset(of: state.summary.accessLost) else {
                    return false
                }
                state.summary.accessLost.formUnion(revoked)
                return true
            }
            if isNew {
                log.notice("Access to a searched place went away; its events are dropped")
                stateChanges.send()
            }
        }
        let refused = (unreadable.union(revoked)).flatMap { plan.placeFolders[$0] ?? [] }
        var events: [FileEvent] = []
        for path in paths where plan.allows(path) {
            guard !refused.contains(where: { Paths.isInside(path, $0) }) else { continue }
            events.append(FileEvent(path: path, flags: flags[path] ?? 0))
        }
        guard !events.isEmpty else {
            hold(mark, generation: generation)
            return
        }
        do {
            guard try maker.apply(events, to: index, cancellation: cancellation) else {
                hold(mark, generation: generation)
                return
            }
        } catch {
            // A batch the close stopped changed nothing, so the mark the index holds stays true and the
            // next start replays this batch from it.
            if (error as? CoreError) == .cancelled { return }
            log.error("A batch of file events could not be applied: \(String(describing: error), privacy: .public)")
            // The index may miss this batch, so no saved mark may claim it. The next start walks again.
            state.withLock { state in
                guard state.generation == generation else { return }
                state.mark = nil
                state.dirty = true
            }
            return
        }
        let found = Self.unreadablePlaces(in: index, plan: plan)
        let count = (try? index.count()) ?? 0
        let now = clock.now
        let changed = state.withLock { state -> Bool? in
            guard state.generation == generation, state.index === index else { return nil }
            state.dirty = true
            if let mark { state.mark = mark }
            state.summary.count = count
            state.summary.updatedAt = now
            let before = state.summary.unreadable
            state.summary.unreadable.formUnion(found)
            return state.summary.unreadable != before
        }
        guard let changed else { return }
        contentChanges.send()
        if changed { stateChanges.send() }
        scheduleSave()
    }

    /// Records that the index holds everything up to `mark`, after a batch that changed nothing.
    private func hold(_ mark: FileChangeMark?, generation: Int) {
        guard let mark else { return }
        state.withLock { state in
            if state.generation == generation { state.mark = mark }
        }
    }

    // MARK: - Saving

    /// Saves after the index has been still for ``quietPeriod``. A later change starts the wait
    /// again.
    private func scheduleSave() {
        let clock = clock
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await clock.sleep(for: Self.quietPeriod)
            } catch {
                return
            }
            await self?.save()
        }
        state.withLock { state in
            state.saveTask?.cancel()
            state.saveTask = task
        }
    }

    /// Saves now when anything changed since the last save.
    func save() async {
        await onQueue { [self] in saveNow() }
    }

    private func saveNow() {
        let taken = state.withLock { state -> (FileIndex, FileChangeMark?)? in
            guard state.dirty, let index = state.index else { return nil }
            state.dirty = false
            return (index, state.mark)
        }
        guard let (index, mark) = taken else { return }
        do {
            try maker.save(index, to: file, mark: mark)
        } catch {
            state.withLock { $0.dirty = true }
            log.error("The file index could not be saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops a walk that runs at its next folder, saves what changed, then lets the index go, so
    /// the memory returns while the feature is off.
    func close() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            defer { state.saveTask = nil }
            return state.saveTask
        }
        task?.cancel()
        cancellation?.cancel()
        await save()
        state.withLock { state in
            state.generation += 1
            state.index = nil
            state.plan = nil
            state.pending = []
            state.pendingFlags = [:]
            state.pendingMark = nil
            state.mark = nil
            state.dirty = false
            state.summary = IndexSummary()
        }
        // Every walk queued before the close has ended, so the flag can stop the next one.
        await onQueue { [self] in cancellation?.reset() }
        stateChanges.send()
    }

    /// Returns once everything queued so far has run. For tests and for the feature's own waits.
    func waitUntilIdle() async {
        await onQueue {}
    }

    /// Returns once the save waiting for a quiet moment, if any, has run or was called off.
    func waitForScheduledSave() async {
        await state.withLock { $0.saveTask }?.value
    }

    // MARK: - Helpers

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// The searched protected places whose folders the walker could not read. An expected folder
    /// that is not in the index at all, such as a missing iCloud Drive folder, counts as not read.
    static func unreadablePlaces(in index: FileIndex, plan: ScopePlan) -> Set<ProtectedPlace> {
        guard let snapshot = try? index.snapshot() else { return [] }
        var places: Set<ProtectedPlace> = []
        for (place, folders) in plan.placeFolders {
            for folder in folders {
                guard let id = snapshot.lookup(path: folder) else {
                    if plan.expected.contains(folder) { places.insert(place) }
                    continue
                }
                if snapshot.entry(id)?.flags.contains(.unreadable) == true { places.insert(place) }
            }
        }
        return places
    }
}
