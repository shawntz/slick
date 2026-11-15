import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Platform

/// The text expansion service over a fake key source, a recording poster and fake permissions. No
/// tap is created and nothing is typed.
@Suite(.timeLimit(.minutes(1))) struct TextExpansionTests {
    let permissions = FakePermissions()
    let source = FakeKeySource()
    let poster = RecordingKeystrokePoster()
    let secure = FakeSecureInput()
    let frontmost = Locked<String?>("com.example.editor")
    let focus = FocusFeed()

    func makeCenter() -> TextExpansionCenter {
        let frontmost = frontmost
        let focus = focus
        return TextExpansionCenter(
            permissions: permissions, source: source, poster: poster, secureInput: secure,
            frontmostBundleID: { frontmost.value }, focusChanges: { focus.stream() },
            clickRecheckDelay: .milliseconds(10))
    }

    static let snippets: @Sendable (String) async -> ExpansionResult = { keyword in
        switch keyword {
        case ";sig": .insert(Expansion("Best,\nSam", charactersAfterCursor: 0))
        case ";br": .insert(Expansion("<br>", charactersAfterCursor: 4))
        case ";mtg": .runCommand(ItemID("cmd", "snippets.meeting"), arguments: ["room": "one"])
        default: .ignore
        }
    }

    @Test func typingAKeywordReplacesIt() async throws {
        let center = makeCenter()
        #expect(
            await center.start(keywords: [";sig", ";br"], options: ExpansionOptions(), expand: Self.snippets)
                == .running)
        #expect(source.startCount == 1)
        source.type("hi ;sig")
        try await waitUntil { poster.posted.count == 5 }
        #expect(poster.posted == Keystroke.deletes(4) + [.text("Best,\nSam")])

        source.type(" ;br")
        try await waitUntil { poster.posted.count == 5 + 8 }
        #expect(Array(poster.posted.suffix(8)) == Keystroke.deletes(3) + [.text("<br>")] + Keystroke.lefts(4))
        await center.stop()
    }

    @Test func aCommandKeywordIsDeletedAndHandedToTheHost() async throws {
        let center = makeCenter()
        let runs = Locked<[CommandRun]>([])
        center.setCommandRunner { id, arguments in runs.withLock { $0.append(CommandRun(id: id, arguments: arguments)) }
        }
        _ = await center.start(keywords: [";mtg"], options: ExpansionOptions(), expand: Self.snippets)
        source.type(";mtg")
        try await waitUntil { !runs.value.isEmpty }
        #expect(poster.posted == Keystroke.deletes(4))
        #expect(runs.value == [CommandRun(id: ItemID("cmd", "snippets.meeting"), arguments: ["room": "one"])])
        await center.stop()
    }

    @Test func ignoredKeywordsAndExcludedAppsTypeNothing() async throws {
        let center = makeCenter()
        let asked = Locked(0)
        let options = ExpansionOptions(excludedBundleIDs: ["com.example.passwords"])
        _ = await center.start(keywords: [";sig", ";other"], options: options) { keyword in
            asked.withLock { $0 += 1 }
            return await Self.snippets(keyword)
        }
        source.type(";other")
        try await waitUntil { asked.value == 1 }
        frontmost.value = "com.example.passwords"
        source.type(" ;sig")
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked.value == 1)
        #expect(poster.posted.isEmpty)
        await center.stop()
    }

    @Test func withoutInputMonitoringNoTapIsMadeUntilTheUserGrantsIt() async throws {
        permissions.set(.inputMonitoring, to: .notDetermined)
        let center = makeCenter()
        var statuses = center.statusChanges().makeAsyncIterator()
        #expect(
            await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
                == .needsPermission(.inputMonitoring))
        #expect(await statuses.next() == .needsPermission(.inputMonitoring))
        #expect(source.startCount == 0)
        #expect(permissions.requests.isEmpty)

        permissions.set(.inputMonitoring, to: .granted)
        #expect(await statuses.next() == .running)
        #expect(source.startCount == 1)
        #expect(await center.status() == .running)
        await center.stop()
        #expect(await statuses.next() == .stopped)
    }

    @Test func withoutAccessibilityNothingStarts() async {
        permissions.set(.accessibility, to: .denied)
        let center = makeCenter()
        #expect(
            await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
                == .needsPermission(.accessibility))
        #expect(source.startCount == 0)
        await center.stop()
    }

    @Test func theLastStartOrStopWins() async throws {
        permissions.set(.inputMonitoring, to: .notDetermined)
        let center = makeCenter()
        _ = await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
        await center.stop()
        // The grant arrives after the stop: nothing starts.
        permissions.set(.inputMonitoring, to: .granted)
        await permissions.settle()
        try await Task.sleep(for: .milliseconds(30))
        #expect(source.startCount == 0)
        #expect(await center.status() == .stopped)

        #expect(await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets) == .running)
        await center.stop()
        #expect(source.stopCount == 1)
        source.type(";sig")
        try await Task.sleep(for: .milliseconds(30))
        #expect(poster.posted.isEmpty)
    }

    /// Creating the tap can wait on the system, so it never happens on the caller's main thread.
    /// Calls made from separate tasks still apply in the order they were made.
    @Test func startRunsOffTheMainThreadAndCallsKeepTheirOrder() async {
        let center = makeCenter()
        let first = Task { await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets) }
        let second = Task { await center.stop() }
        let third = Task { await center.start(keywords: [";br"], options: ExpansionOptions(), expand: Self.snippets) }
        _ = await first.value
        await second.value
        #expect(await third.value == .running)
        #expect(center.keywords == [";br"])
        #expect(source.startCount == 2 && source.stopCount == 1)
        #expect(source.startedOnMainThread == false)
        await center.stop()
    }

    @Test func keywordsUpdateWithoutARestart() async throws {
        let center = makeCenter()
        _ = await center.start(keywords: [";br"], options: ExpansionOptions(), expand: Self.snippets)
        await center.updateKeywords([";sig"])
        #expect(center.keywords == [";sig"])
        #expect(source.startCount == 1)
        source.type(";sig")
        try await waitUntil { !poster.posted.isEmpty }
        await center.stop()
    }

    @Test func secureInputIsReportedAndClearsOnTheNextKey() async throws {
        secure.set(SecureInputState(isOn: true, owner: "Example Passwords"))
        let center = makeCenter()
        var statuses = center.statusChanges().makeAsyncIterator()
        #expect(
            await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
                == .blockedBySecureInput(owner: "Example Passwords"))
        #expect(await statuses.next() == .blockedBySecureInput(owner: "Example Passwords"))
        secure.set(.off)
        source.send(.characters("x"))
        #expect(await statuses.next() == .running)

        // A click checks again shortly after, since the click may have focused a password field.
        secure.set(SecureInputState(isOn: true))
        source.send(.click)
        #expect(await statuses.next() == .blockedBySecureInput(owner: nil))
        await center.stop()
    }

    @Test func anotherAppComingForwardClearsTheBuffer() async throws {
        let center = makeCenter()
        _ = await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
        try await waitUntil { focus.listenerCount == 1 }
        source.type(";si")
        focus.send()
        try await Task.sleep(for: .milliseconds(30))
        source.type("g")
        try await Task.sleep(for: .milliseconds(30))
        #expect(poster.posted.isEmpty)
        await center.stop()
        try await waitUntil { focus.listenerCount == 0 }
    }

    @Test func revokedAccessibilityTypesNothing() async throws {
        let center = makeCenter()
        _ = await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: Self.snippets)
        poster.isAllowed = false
        source.type(";sig")
        try await Task.sleep(for: .milliseconds(50))
        #expect(poster.posted.isEmpty)
        await center.stop()
    }
}

/// A key source that tests type into. It never touches the keyboard.
nonisolated final class FakeKeySource: KeyEventSource {
    private struct State {
        var handler: (@Sendable (TypingEvent) -> Void)?
        var starts = 0
        var stops = 0
        var startedOnMainThread: Bool?
    }

    private let state = Mutex(State())

    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }
    /// Whether any start ran on the main thread, or nil before the first.
    var startedOnMainThread: Bool? { state.withLock { $0.startedOnMainThread } }

    func start(_ handler: @escaping @Sendable (TypingEvent) -> Void) -> Bool {
        let onMain = Thread.isMainThread
        state.withLock { state in
            if state.handler == nil { state.starts += 1 }
            state.handler = handler
            state.startedOnMainThread = (state.startedOnMainThread ?? false) || onMain
        }
        return true
    }

    func stop() {
        state.withLock { state in
            if state.handler != nil { state.stops += 1 }
            state.handler = nil
        }
    }

    /// Plays one event.
    func send(_ event: TypingEvent) {
        state.withLock { $0.handler }?(event)
    }

    /// Plays each character typed as its own key press.
    func type(_ text: String) {
        for character in text {
            send(.characters(String(character)))
        }
    }
}

/// A secure input reader with a state tests set.
nonisolated final class FakeSecureInput: SecureInputReader {
    private let state = Mutex(SecureInputState.off)

    func set(_ value: SecureInputState) {
        state.withLock { $0 = value }
    }

    func current() -> SecureInputState {
        state.withLock { $0 }
    }
}

/// Plays other apps coming forward.
nonisolated final class FocusFeed: Sendable {
    private let broadcast = Broadcast<Void>()

    var listenerCount: Int { broadcast.listenerCount }

    func stream() -> AsyncStream<Void> {
        broadcast.stream()
    }

    func send() {
        broadcast.send(())
    }
}

/// A value behind a lock, for closures that tests hand to services.
nonisolated final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
