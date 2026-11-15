import AppKit
import Foundation
import Kit
import Synchronization

/// The live pasteboard service, over an `NSPasteboard` it is handed: the general pasteboard in the
/// app, a private named one in tests and outside `live`.
///
/// - Every read and write runs on one private serial queue, never on the caller's thread.
/// - ``entries()`` polls `changeCount` on that queue every ``pollInterval`` (4 Hz), and only while
///   at least one stream is open. A change is reported only when its marker types allow it, it
///   was not written by this app, and the pasteboard permission is granted, because on a future
///   macOS a read without it would raise the system's alert.
/// - What this service writes is marked transient, with this app as its source, so clipboard
///   managers and this app's own history skip it. ``CopyOptions/concealed`` adds the concealed
///   marker.
/// - ``paste(_:charactersAfterCursor:)`` writes, closes the panel through the hook the app sets,
///   waits until another app is frontmost and no window of this app has key focus, then sends
///   Command-V and one Left press per character to leave after the insertion point. When this app
///   keeps key focus, it throws ``PasteError/targetDidNotActivate`` instead of pasting into its
///   own hidden panel; the text stays on the pasteboard.
/// - ``recentText(offset:)`` asks the clipboard history the app registers with
///   ``setHistoryReader(_:)``. Without one it answers from the current text and the texts this
///   service saw since launch.
nonisolated public final class LivePasteboard: PasteboardService {
    /// How often ``entries()`` checks for a change while a stream is open.
    public let pollInterval: Duration
    /// The bundle ID written as the source of this app's writes.
    public let ownBundleID: String
    /// Images larger than this are left out of entries.
    public let maximumImageBytes: Int
    /// RTF larger than this is left out of entries; the plain text stays.
    public let maximumRichTextBytes: Int

    private let board: PasteboardBox
    private let queue = DispatchQueue(label: "platform.pasteboard", qos: .utility)
    private let poll: PollState
    private let permissions: any PermissionService
    private let poster: any KeystrokePoster
    private let clock: any ClockService
    private let sourceApplication: @Sendable () -> String?
    private let anotherAppIsFrontmost: @Sendable () async -> Bool
    private let broadcast = Broadcast<PasteboardEntry>()
    private let state = Mutex(State())
    private let recentLimit = 32

    private struct State {
        var recentTexts: [String] = []
        var ownChangeCounts: [Int] = []
        var history: (any ClipboardHistoryReader)?
        var panelCloser: (@MainActor @Sendable () -> Void)?
    }

    /// - Parameters:
    ///   - pasteboard: The pasteboard to use. Only this service may touch it from now on.
    ///   - permissions: Where the pasteboard permission is read. Never asked.
    ///   - poster: Sends Command-V and the Left presses.
    ///   - sourceApplication: The bundle ID of the frontmost app other than this one, for an entry
    ///     whose writer left no source marker.
    ///   - anotherAppIsFrontmost: Waits briefly for the app that should receive a paste to be
    ///     frontmost, and says whether it is. ``waitForAnotherApp(ownProcessID:timeout:)`` is the
    ///     live one.
    public init(
        pasteboard: NSPasteboard,
        permissions: any PermissionService,
        poster: any KeystrokePoster,
        clock: any ClockService,
        sourceApplication: @escaping @Sendable () -> String? = { nil },
        anotherAppIsFrontmost: @escaping @Sendable () async -> Bool = { true },
        ownBundleID: String = Brand.bundleID,
        pollInterval: Duration = .milliseconds(250),
        maximumImageBytes: Int = 16 << 20,
        maximumRichTextBytes: Int = 16 << 20
    ) {
        board = PasteboardBox(pasteboard)
        poll = PollState(lastSeen: pasteboard.changeCount)
        self.permissions = permissions
        self.poster = poster
        self.clock = clock
        self.sourceApplication = sourceApplication
        self.anotherAppIsFrontmost = anotherAppIsFrontmost
        self.ownBundleID = ownBundleID
        self.pollInterval = pollInterval
        self.maximumImageBytes = maximumImageBytes
        self.maximumRichTextBytes = maximumRichTextBytes
    }

    deinit {
        // A resumed timer lives on its own; without this it would fire for good.
        poll.timer?.cancel()
    }

    // MARK: Hooks the app sets

    /// Sets the clipboard history that answers ``recentText(offset:)``, or nil to answer from
    /// what this service saw. The app sets it while the providing feature is on.
    public func setHistoryReader(_ reader: (any ClipboardHistoryReader)?) {
        state.withLock { $0.history = reader }
    }

    /// Sets what closes the panel before a paste, so the previous app comes forward.
    public func setPanelCloser(_ close: (@MainActor @Sendable () -> Void)?) {
        state.withLock { $0.panelCloser = close }
    }

    // MARK: PasteboardService

    public var changeCount: Int {
        board.pasteboard.changeCount
    }

    public func copy(_ content: PasteboardContent, options: CopyOptions) async {
        let markers = markers(for: options)
        await onQueue { [self] in
            let pasteboard = board.pasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects(PasteboardContents.items(for: content, markers: markers))
            let count = pasteboard.changeCount
            state.withLock { state in
                state.ownChangeCounts.append(count)
                if state.ownChangeCounts.count > 16 { state.ownChangeCounts.removeFirst() }
            }
            if !options.contains(.concealed) { remember(content.plainText) }
        }
    }

    public func paste(_ content: PasteboardContent, charactersAfterCursor: Int) async throws {
        await copy(content, options: [])
        guard poster.canPost() else { throw PasteError.permissionMissing(.accessibility) }
        if let close = state.withLock({ $0.panelCloser }) {
            await MainActor.run { close() }
        }
        guard await anotherAppIsFrontmost() else { throw PasteError.targetDidNotActivate }
        try await poster.post([.paste] + Keystroke.lefts(charactersAfterCursor))
    }

    /// The current contents, unless they are concealed, or transient or auto-generated by another
    /// app. What this app wrote itself is returned.
    @concurrent public func read() async -> PasteboardEntry? {
        let date = clock.now
        return await onQueue { [self] in
            let pasteboard = board.pasteboard
            let verdict = PasteboardMarkers.verdict(for: (pasteboard.types ?? []).map(\.rawValue))
            if verdict.isConcealed { return nil }
            let source = pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardMarkers.source))
            if !verdict.mayRecord, source != ownBundleID { return nil }
            let contents = PasteboardContents.read(
                from: pasteboard, maximumImageBytes: maximumImageBytes, maximumRichTextBytes: maximumRichTextBytes)
            guard !contents.isEmpty else { return nil }
            return PasteboardEntry(
                contents: contents, sourceBundleID: source, date: date, changeCount: pasteboard.changeCount)
        }
    }

    @concurrent public func recentText(offset: Int) async -> String? {
        guard offset >= 0 else { return nil }
        let current = await read()?.plainText
        if let history = state.withLock({ $0.history }) {
            // Offset 0 is the current text. The history leaves out what this app copied itself,
            // so when the current text is not the history's newest entry, the history starts at 1.
            guard let current else { return await history.text(offset: offset) }
            if offset == 0 { return current }
            let shift = await history.text(offset: 0) == current ? 0 : 1
            return await history.text(offset: offset - shift)
        }
        var texts = state.withLock { $0.recentTexts }
        if let current, texts.first != current {
            texts.insert(current, at: 0)
        }
        return texts.indices.contains(offset) ? texts[offset] : nil
    }

    public func entries() -> AsyncStream<PasteboardEntry> {
        let stream = broadcast.stream(onEnd: { [weak self] in self?.subscriberLeft() }, { $0 })
        queue.async { [self] in
            poll.subscribers += 1
            if poll.subscribers == 1 { startPolling() }
        }
        return stream
    }

    // MARK: Polling

    /// True while a timer checks for changes. For tests.
    var isPolling: Bool {
        queue.sync { poll.timer != nil }
    }

    private func subscriberLeft() {
        queue.async { [self] in
            poll.subscribers -= 1
            if poll.subscribers == 0 { stopPolling() }
        }
    }

    /// On `queue`.
    private func startPolling() {
        poll.lastSeen = board.pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(pollInterval.timeInterval * 1e9))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.checkForChange() }
        timer.resume()
        poll.timer = timer
    }

    /// On `queue`.
    private func stopPolling() {
        poll.timer?.cancel()
        poll.timer = nil
    }

    /// On `queue`. Reports one change made by another app, if the rules allow it.
    private func checkForChange() {
        let pasteboard = board.pasteboard
        let count = pasteboard.changeCount
        guard count != poll.lastSeen else { return }
        poll.lastSeen = count
        guard !state.withLock({ $0.ownChangeCounts.contains(count) }) else { return }
        let verdict = PasteboardMarkers.verdict(for: (pasteboard.types ?? []).map(\.rawValue))
        guard verdict.mayRecord else { return }
        // On a macOS that guards the pasteboard, reading the data would raise the system's alert.
        guard permissions.status(of: .pasteboard) == .granted else { return }
        let source = pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardMarkers.source))
        guard source != ownBundleID else { return }
        let contents = PasteboardContents.read(
            from: pasteboard, maximumImageBytes: maximumImageBytes, maximumRichTextBytes: maximumRichTextBytes)
        guard !contents.isEmpty else { return }
        let entry = PasteboardEntry(
            contents: contents, sourceBundleID: source ?? sourceApplication(), date: clock.now, changeCount: count)
        remember(entry.plainText)
        broadcast.send(entry)
    }

    // MARK: Helpers

    private func markers(for options: CopyOptions) -> [(type: String, value: String)] {
        var markers = [(PasteboardMarkers.transient, ""), (PasteboardMarkers.source, ownBundleID)]
        if options.contains(.concealed) { markers.append((PasteboardMarkers.concealed, "")) }
        return markers.map { (type: $0.0, value: $0.1) }
    }

    private func remember(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        state.withLock { state in
            state.recentTexts.removeAll { $0 == text }
            state.recentTexts.insert(text, at: 0)
            if state.recentTexts.count > recentLimit { state.recentTexts.removeLast() }
        }
    }

    /// Runs `body` on the pasteboard queue and returns its result.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Runs `body` with the pasteboard on its queue, as another app writing would. For tests.
    func withPasteboard<T: Sendable>(_ body: @escaping @Sendable (NSPasteboard) -> T) async -> T {
        await onQueue { [board] in body(board.pasteboard) }
    }

    /// Waits up to `timeout` until a paste would reach another app, checking every 10 ms on the
    /// main thread: ``isReadyToPaste(frontmostProcessID:ownProcessID:ownWindowIsKey:)``. The panel
    /// never activates the app, so another app is usually frontmost at once; key focus leaves the
    /// panel a moment after it closes.
    public static func waitForAnotherApp(
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier, timeout: Duration = .seconds(1),
        ownWindowIsKey: @escaping @Sendable () -> Bool = { false }
    ) -> @Sendable () async -> Bool {
        {
            let deadline = ContinuousClock.now + timeout
            while true {
                let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                if isReadyToPaste(
                    frontmostProcessID: frontmost, ownProcessID: ownProcessID, ownWindowIsKey: ownWindowIsKey())
                {
                    return true
                }
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// True when Command-V would reach another app: one is frontmost, and no window of this app
    /// holds key focus. The launcher's panel takes key focus without activating the app, so the
    /// frontmost app alone does not say where a keystroke goes.
    public static func isReadyToPaste(frontmostProcessID: pid_t?, ownProcessID: pid_t, ownWindowIsKey: Bool) -> Bool {
        guard let frontmostProcessID, frontmostProcessID != ownProcessID else { return false }
        return !ownWindowIsKey
    }
}

/// An `NSPasteboard` that only the pasteboard queue touches, apart from `changeCount`.
nonisolated final class PasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }
}

/// The polling state. Touched only on the pasteboard queue.
nonisolated final class PollState: @unchecked Sendable {
    var subscribers = 0
    var timer: (any DispatchSourceTimer)?
    var lastSeen: Int

    init(lastSeen: Int) {
        self.lastSeen = lastSeen
    }
}
