import Foundation
import Kit
import Synchronization

/// A pasteboard in memory. It records what was copied and pasted, and lets a test play another app
/// copying something with ``simulateCopy(_:from:)``. It never touches the system pasteboard.
public final class FakePasteboard: PasteboardService {
    /// One paste: what was pasted and where the insertion point was left.
    public struct Paste: Hashable, Sendable {
        public var content: PasteboardContent
        public var charactersAfterCursor: Int
    }

    private struct State {
        var current: PasteboardEntry?
        var copied: [PasteboardContent] = []
        var pastes: [Paste] = []
        var textsNewestFirst: [String] = []
        var changeCount = 0
        var pasteFailure: PasteError?
    }

    private let state = Mutex(State())
    private let clock: any ClockService
    private let broadcast = FakeBroadcast<PasteboardEntry>()

    public init(clock: any ClockService = SystemClock()) {
        self.clock = clock
    }

    /// Everything copied through the service, oldest first.
    public var copied: [PasteboardContent] { state.withLock { $0.copied } }
    /// The plain text of everything copied, oldest first.
    public var copiedTexts: [String] { copied.compactMap(\.plainText) }
    /// Every paste, oldest first, with where the insertion point was left.
    public var pastes: [Paste] { state.withLock { $0.pastes } }
    /// Everything pasted through the service, oldest first.
    public var pasted: [PasteboardContent] { pastes.map(\.content) }
    /// The plain text of everything pasted, oldest first.
    public var pastedTexts: [String] { pasted.compactMap(\.plainText) }

    /// When set, ``paste(_:charactersAfterCursor:)`` throws this instead of pasting.
    public var pasteFailure: PasteError? {
        get { state.withLock { $0.pasteFailure } }
        set { state.withLock { $0.pasteFailure = newValue } }
    }

    /// Plays another app copying something: the contents become current and every ``entries()``
    /// stream receives the entry. Follow it with `FeatureHarness.settle()` to wait until the
    /// feature's monitor has handled it.
    @discardableResult
    public func simulateCopy(_ contents: [PasteboardContent], from bundleID: String? = nil) -> PasteboardEntry {
        let date = clock.now
        let entry = state.withLock { state in
            state.changeCount += 1
            let entry = PasteboardEntry(
                contents: contents, sourceBundleID: bundleID, date: date, changeCount: state.changeCount)
            state.current = entry
            if let text = entry.plainText { state.textsNewestFirst.insert(text, at: 0) }
            return entry
        }
        broadcast.send(entry)
        return entry
    }

    /// Plays another app copying plain text.
    @discardableResult
    public func simulateCopy(_ text: String, from bundleID: String? = nil) -> PasteboardEntry {
        simulateCopy([.text(text)], from: bundleID)
    }

    /// Returns once every ``entries()`` consumer has handled every entry it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    public func copy(_ content: PasteboardContent, options: CopyOptions) async {
        let date = clock.now
        state.withLock { state in
            state.copied.append(content)
            state.changeCount += 1
            state.current = PasteboardEntry(contents: [content], date: date, changeCount: state.changeCount)
            if let text = content.plainText { state.textsNewestFirst.insert(text, at: 0) }
        }
    }

    public func paste(_ content: PasteboardContent, charactersAfterCursor: Int) async throws {
        if let failure = pasteFailure { throw failure }
        await copy(content, options: [])
        state.withLock { $0.pastes.append(Paste(content: content, charactersAfterCursor: charactersAfterCursor)) }
    }

    public func read() async -> PasteboardEntry? {
        state.withLock { $0.current }
    }

    public func recentText(offset: Int) async -> String? {
        state.withLock { state in
            state.textsNewestFirst.indices.contains(offset) ? state.textsNewestFirst[offset] : nil
        }
    }

    public var changeCount: Int { state.withLock { $0.changeCount } }

    public func entries() -> AsyncStream<PasteboardEntry> {
        broadcast.stream()
    }
}
