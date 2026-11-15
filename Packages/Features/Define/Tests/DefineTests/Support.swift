import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Define

/// A lookup service over the fixtures that records every call. With `holdsCalls`, each call waits
/// at a gate after it is recorded, as a slow system call would, until the test opens the gate.
nonisolated final class RecordingLookup: LookupService {
    private let base: FixtureLookup
    private let calls = Mutex<[String]>([])
    private let gate: Gate?
    let entered: AsyncStream<String>
    private let enteredContinuation: AsyncStream<String>.Continuation

    init(base: FixtureLookup = FixtureLookup(), holdsCalls: Bool = false) {
        self.base = base
        gate = holdsCalls ? Gate() : nil
        (entered, enteredContinuation) = AsyncStream.makeStream()
    }

    /// Every call, oldest first, as "definition:<term>" or "spelling:<word>".
    var recorded: [String] { calls.withLock { $0 } }

    /// Lets every held call, and every later one, go on.
    func open() async {
        await gate?.open()
    }

    @concurrent func definitionText(for term: String) async throws -> String? {
        try await hold("definition:" + term)
        return try await base.definitionText(for: term)
    }

    @concurrent func spelling(of word: String) async throws -> Spelling {
        try await hold("spelling:" + word)
        return try await base.spelling(of: word)
    }

    /// Records the call, waits at the gate the way an uninterruptible system call would, then
    /// stops if the caller was cancelled meanwhile.
    private func hold(_ call: String) async throws {
        calls.withLock { $0.append(call) }
        enteredContinuation.yield(call)
        if let gate { await gate.wait() }
        try Task.checkCancellation()
    }
}

/// Holds callers until it is opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A harness for the feature over the fakes, with the lookup service replaced.
func makeHarness(
    _ lookup: RecordingLookup = RecordingLookup(), fakes: FakeServices = FakeServices()
) -> FeatureHarness<DictionaryFeature> {
    fakes.override(LookupServiceKey.self, with: lookup)
    return FeatureHarness(DictionaryFeature.self, fakes: fakes)
}

extension FeatureHarness {
    /// The titles of the visible rows, in order.
    var titles: [String] { rows.map(\.title) }

    /// The IDs of the actions the action panel would show.
    var actionIDs: [String] { actions().map(\.id) }

    /// The top page's title.
    var pageTitle: String? {
        switch page?.page {
        case .detail(let detail): detail.title
        case .list(let list): list.title
        case .grid(let grid): grid.title
        case .form(let form): form.title
        case nil: nil
        }
    }

    /// The Markdown the top detail page shows.
    var shownMarkdown: String? {
        guard case .markdown(let text) = detail?.body else { return nil }
        return text
    }
}

/// Waits for the next call to enter the service.
func nextCall(_ lookup: RecordingLookup) async -> String? {
    for await call in lookup.entered { return call }
    return nil
}
