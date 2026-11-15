import Kit
import Synchronization

/// Text expansion without a keyboard tap. ``type(_:)`` plays the user typing a keyword in another
/// app and returns what the feature decided.
public final class FakeTextExpansion: TextExpansionService {
    private struct State {
        var keywords: Set<String> = []
        var options = ExpansionOptions()
        var handler: (@Sendable (String) async -> ExpansionResult)?
        var status: TextExpansionStatus = .stopped
        var missingPermission: Permission?
        var inserted: [Expansion] = []
        var commandRuns: [CommandRun] = []
    }

    private let state = Mutex(State())
    private let broadcast = FakeBroadcast<TextExpansionStatus>()

    public init() {}

    /// When set, ``start(keywords:options:expand:)`` reports that this permission is missing.
    public var missingPermission: Permission? {
        get { state.withLock { $0.missingPermission } }
        set { state.withLock { $0.missingPermission = newValue } }
    }

    /// The keywords being watched.
    public var keywords: Set<String> { state.withLock { $0.keywords } }
    /// The options passed to the last start.
    public var options: ExpansionOptions { state.withLock { $0.options } }
    /// Every expansion inserted, oldest first.
    public var inserted: [Expansion] { state.withLock { $0.inserted } }
    /// Every command a typed keyword opened, oldest first.
    public var commandRuns: [CommandRun] { state.withLock { $0.commandRuns } }

    /// Plays the user typing a keyword. Returns what the feature's handler decided, or nil when the
    /// service is not running or the keyword is not watched. Insertions and command runs are recorded.
    public func type(_ keyword: String) async -> ExpansionResult? {
        let handler = state.withLock { state in
            state.status == .running && state.keywords.contains(keyword) ? state.handler : nil
        }
        guard let handler else { return nil }
        let result = await handler(keyword)
        state.withLock { state in
            switch result {
            case .insert(let expansion): state.inserted.append(expansion)
            case .runCommand(let id, let arguments): state.commandRuns.append(CommandRun(id: id, arguments: arguments))
            case .ignore: break
            }
        }
        return result
    }

    /// Plays the status changing by itself, such as secure input starting in another app or the
    /// user granting Input Monitoring. Every ``statusChanges()`` stream hears of it.
    public func simulateStatus(_ status: TextExpansionStatus) {
        state.withLock { $0.status = status }
        broadcast.send(status)
    }

    /// Returns once every ``statusChanges()`` consumer has handled every status it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    public func start(
        keywords: Set<String>, options: ExpansionOptions, expand: @escaping @Sendable (String) async -> ExpansionResult
    ) async -> TextExpansionStatus {
        let status = state.withLock { state in
            if let missing = state.missingPermission {
                state.status = .needsPermission(missing)
                return state.status
            }
            state.keywords = keywords
            state.options = options
            state.handler = expand
            state.status = .running
            return state.status
        }
        broadcast.send(status)
        return status
    }

    public func updateKeywords(_ keywords: Set<String>) async {
        state.withLock { $0.keywords = keywords }
    }

    public func stop() async {
        state.withLock { state in
            state.status = .stopped
            state.handler = nil
        }
        broadcast.send(.stopped)
    }

    public func status() async -> TextExpansionStatus {
        state.withLock { $0.status }
    }

    public func statusChanges() -> AsyncStream<TextExpansionStatus> {
        broadcast.stream()
    }
}
