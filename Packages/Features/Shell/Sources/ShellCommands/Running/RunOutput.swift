import Foundation
import Kit
import Synchronization

/// One run's output and metadata, shared by the task that reads the process and by the pages that
/// show the run.
///
/// The reader appends off the main thread. A page pulls: each time the host asks the page's stream
/// for its next update, the page gets everything that changed since its last one, as one update.
/// A command that prints without end, such as `yes`, therefore never piles updates up behind a page
/// that draws slower than the command prints. The host's work follows how fast it draws, and the
/// output itself stays within its limit.
///
/// A page's first update is the whole detail as it stands. After that come the text appended
/// since, the whole detail again when the start was dropped, and the new metadata, in that order.
/// When the run has ended and the page has everything, its stream ends. Leaving the page, or the
/// host cancelling its stream, lets the page go and the run goes on.
nonisolated final class RunOutput: Sendable {
    typealias Waiter = CheckedContinuation<Void, Never>

    /// What one page has had so far.
    private struct Watcher {
        /// How many times the start had been dropped at the page's last update. Nil before its first.
        var trims: Int?
        /// UTF-8 bytes of the kept text the page has.
        var sent = 0
        var factsVersion = 0
        /// True once the page's task was cancelled.
        var isCancelled = false
        /// The page's pull, while it waits for a change.
        var waiter: Waiter?
    }

    private struct State {
        var buffer: OutputBuffer
        var facts: RunFacts
        var factsVersion = 0
        /// How many times the start was dropped.
        var trims = 0
        var watchers: [Int: Watcher] = [:]
        var nextWatcher = 0
        var isFinished = false
        var attachWaiters: [Waiter] = []

        var metadata: [MetadataItem] {
            facts.metadata(droppedBytes: buffer.dropped)
        }

        var detail: Detail {
            Detail(.text(buffer.text, monospaced: true), metadata: metadata)
        }

        /// True when a page has an update waiting.
        func hasNews(for id: Int) -> Bool {
            guard let watcher = watchers[id] else { return false }
            return watcher.trims != trims || watcher.sent < buffer.count || watcher.factsVersion != factsVersion
        }

        /// The page's next update, everything since its last one, or nil when it has everything.
        mutating func update(for id: Int) -> DetailUpdate? {
            guard var watcher = watchers[id] else { return nil }
            defer { watchers[id] = watcher }
            if watcher.trims != trims {
                watcher.trims = trims
                watcher.sent = buffer.count
                watcher.factsVersion = factsVersion
                return .replace(detail)
            }
            if watcher.sent < buffer.count {
                let text = buffer.text(fromByte: watcher.sent)
                watcher.sent = buffer.count
                return .append(text)
            }
            if watcher.factsVersion != factsVersion {
                watcher.factsVersion = factsVersion
                return .metadata(metadata)
            }
            return nil
        }

        /// Takes every waiting pull, to resume outside the lock.
        mutating func takeWaiters() -> [Waiter] {
            var waiters: [Waiter] = []
            for id in watchers.keys {
                if let waiter = watchers[id]?.waiter {
                    waiters.append(waiter)
                    watchers[id]?.waiter = nil
                }
            }
            return waiters
        }
    }

    private let state: Mutex<State>

    init(limit: Int, facts: RunFacts) {
        state = Mutex(State(buffer: OutputBuffer(limit: limit), facts: facts))
    }

    /// The output kept now, escape sequences included.
    var text: String {
        state.withLock { $0.buffer.text }
    }

    /// True while nothing was printed.
    var isEmpty: Bool {
        state.withLock { $0.buffer.count == 0 && $0.buffer.dropped == 0 }
    }

    /// UTF-8 bytes dropped from the start.
    var droppedBytes: Int {
        state.withLock { $0.buffer.dropped }
    }

    /// The detail as a page that attaches now would show it.
    var detail: Detail {
        state.withLock { $0.detail }
    }

    /// Adds a chunk of output and wakes every page that waits for it.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let waiters = state.withLock { state -> [Waiter] in
            guard !state.isFinished else { return [] }
            if state.buffer.append(chunk) == .trimmed { state.trims += 1 }
            return state.takeWaiters()
        }
        resume(waiters)
    }

    /// Replaces the facts, such as when the run ends, and wakes every page for the new metadata.
    func update(_ facts: RunFacts) {
        let waiters = state.withLock { state -> [Waiter] in
            state.facts = facts
            state.factsVersion += 1
            return state.takeWaiters()
        }
        resume(waiters)
    }

    /// Starts a page's hold on the output. Returns its ID, or nil when the run has ended: the page
    /// then shows the final detail once.
    func attach() -> Int? {
        let (id, waiters) = state.withLock { state -> (Int?, [Waiter]) in
            guard !state.isFinished else { return (nil, []) }
            let id = state.nextWatcher
            state.nextWatcher += 1
            state.watchers[id] = Watcher()
            defer { state.attachWaiters = [] }
            return (id, state.attachWaiters)
        }
        resume(waiters)
        return id
    }

    /// The next update for a page: everything that changed since its last one. Waits while nothing
    /// changed and the run goes on. Nil once the run ended and the page has everything, once the
    /// page's task was cancelled, or for a page that let go; the page's hold ends then.
    func next(for id: Int) async -> DetailUpdate? {
        enum Step {
            case send(DetailUpdate)
            case end
            case wait
        }
        while true {
            let step = state.withLock { state -> Step in
                guard let watcher = state.watchers[id], !watcher.isCancelled else { return .end }
                if let update = state.update(for: id) { return .send(update) }
                return state.isFinished ? .end : .wait
            }
            switch step {
            case .send(let update):
                return update
            case .end:
                detach(id)
                return nil
            case .wait:
                await waitForChange(id)
            }
        }
    }

    /// Suspends a page's pull until the output, the metadata or the run's state changes, or the
    /// page's task is cancelled.
    private func waitForChange(_ id: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Waiter) in
                let resumeNow = state.withLock { state -> Bool in
                    guard var watcher = state.watchers[id], !watcher.isCancelled, !state.isFinished,
                        !state.hasNews(for: id)
                    else { return true }
                    watcher.waiter = continuation
                    state.watchers[id] = watcher
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                state.watchers[id]?.isCancelled = true
                defer { state.watchers[id]?.waiter = nil }
                return state.watchers[id]?.waiter
            }
            waiter?.resume()
        }
    }

    /// Returns once a page's stream is attached, or at once when one is. For tests, which close the
    /// panel only after the page shows the run.
    func waitUntilWatched() async {
        await withCheckedContinuation { (continuation: Waiter) in
            let ready = state.withLock { state in
                guard state.watchers.isEmpty, !state.isFinished else { return true }
                state.attachWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Ends a page's hold, when the page went away.
    func detach(_ id: Int) {
        let waiter = state.withLock { $0.watchers.removeValue(forKey: id)?.waiter }
        waiter?.resume()
    }

    /// True while a page's stream holds the output.
    func isAttached(_ id: Int) -> Bool {
        state.withLock { $0.watchers[id] != nil }
    }

    /// The number of attached streams. For tests.
    var watcherCount: Int {
        state.withLock { $0.watchers.count }
    }

    /// Marks the run ended. Later appends are ignored, a page's stream ends once it has everything,
    /// and later pages get the final detail.
    func finish() {
        let waiters = state.withLock { state -> [Waiter] in
            state.isFinished = true
            return state.takeWaiters()
        }
        resume(waiters)
    }

    private func resume(_ waiters: [Waiter]) {
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A page's hold on a run's output, as its stream pulls. When the stream ends or goes away, the hold
/// ends with it, so a page the host dropped never counts as watching the run.
nonisolated final class OutputLease: Sendable {
    private let output: RunOutput
    private let id: Int

    init(output: RunOutput, id: Int) {
        self.output = output
        self.id = id
    }

    func next() async -> DetailUpdate? {
        await output.next(for: id)
    }

    deinit {
        output.detach(id)
    }
}
