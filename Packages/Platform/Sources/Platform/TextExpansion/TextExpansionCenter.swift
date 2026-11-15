import Foundation
import Kit
import Synchronization

/// The live text expansion service: a ``TypingBuffer`` fed by a ``KeyEventSource``, typing through
/// a ``KeystrokePoster``.
///
/// - ``start(keywords:options:expand:)`` never prompts. Without Input Monitoring or Accessibility
///   it returns ``TextExpansionStatus/needsPermission(_:)``, creates no tap, and keeps one
///   permission stream open until the user grants it; then it starts by itself and
///   ``statusChanges()`` reports `.running`.
/// - Start, stop and keyword updates run one at a time on a serial queue, never on the caller's
///   thread, in the order they are called, so the last start or stop wins. Creating the tap and
///   checking the permissions can wait on the system for milliseconds.
/// - When a keyword is typed, the feature's handler decides. An insert deletes the keyword and
///   types the text, then presses Left for the characters after the cursor. A command deletes the
///   keyword, then hands the run to the runner the host sets with ``setCommandRunner(_:)``.
///   Nothing expands while an excluded app is frontmost.
/// - Secure input is checked when typing starts, when another app comes forward, shortly after a
///   click, and on the first key after it was seen on, so no timer runs while the user is idle.
nonisolated public final class TextExpansionCenter: TextExpansionService {
    public typealias Handler = @Sendable (String) async -> ExpansionResult
    public typealias CommandRunner = @Sendable (ItemID, [String: String]) async -> Void

    private struct Request {
        var options: ExpansionOptions
        var expand: Handler
    }

    private struct State {
        var request: Request?
        var buffer = TypingBuffer(keywords: [])
        var status: TextExpansionStatus = .stopped
        var isListening = false
        var waitingFor: Permission?
        var permissionWait: Task<Void, Never>?
        var focusWatch: Task<Void, Never>?
        var secureCheckPending = false
        var commandRunner: CommandRunner?
    }

    private let permissions: any PermissionService
    private let source: any KeyEventSource
    private let poster: any KeystrokePoster
    private let secureInput: any SecureInputReader
    private let frontmostBundleID: @Sendable () -> String?
    private let focusChanges: @Sendable () -> AsyncStream<Void>
    private let clickRecheckDelay: Duration
    private let state = Mutex(State())
    /// Runs starts, stops and keyword updates one at a time. Each call is queued before it
    /// suspends, so they apply in call order.
    private let operations = DispatchQueue(label: "platform.text-expansion", qos: .userInitiated)
    private let statuses = Broadcast<TextExpansionStatus>()

    /// - Parameters:
    ///   - permissions: Where Input Monitoring and Accessibility are read. Never asked.
    ///   - source: Where typing comes from.
    ///   - poster: What types the expansion.
    ///   - secureInput: Reads whether another app hides keystrokes.
    ///   - frontmostBundleID: The frontmost app other than this one, for excluded apps.
    ///   - focusChanges: A stream that yields when another app comes forward.
    public init(
        permissions: any PermissionService,
        source: any KeyEventSource,
        poster: any KeystrokePoster,
        secureInput: any SecureInputReader,
        frontmostBundleID: @escaping @Sendable () -> String? = { nil },
        focusChanges: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
        clickRecheckDelay: Duration = .milliseconds(300)
    ) {
        self.permissions = permissions
        self.source = source
        self.poster = poster
        self.secureInput = secureInput
        self.frontmostBundleID = frontmostBundleID
        self.focusChanges = focusChanges
        self.clickRecheckDelay = clickRecheckDelay
    }

    deinit {
        let (wait, watch, listening) = state.withLock { ($0.permissionWait, $0.focusWatch, $0.isListening) }
        wait?.cancel()
        watch?.cancel()
        if listening { source.stop() }
    }

    /// Sets what runs a command when a keyword's answer is ``ExpansionResult/runCommand(_:arguments:)``.
    /// The host opens the panel on it, launched from text expansion.
    public func setCommandRunner(_ runner: CommandRunner?) {
        state.withLock { $0.commandRunner = runner }
    }

    // MARK: TextExpansionService

    public func start(
        keywords: Set<String>, options: ExpansionOptions, expand: @escaping Handler
    ) async -> TextExpansionStatus {
        await withCheckedContinuation { continuation in
            operations.async { [self] in
                state.withLock { state in
                    state.request = Request(options: options, expand: expand)
                    state.buffer.update(keywords: keywords)
                    state.buffer.options = options
                }
                continuation.resume(returning: activate())
            }
        }
    }

    public func updateKeywords(_ keywords: Set<String>) async {
        await withCheckedContinuation { continuation in
            operations.async { [self] in
                state.withLock { $0.buffer.update(keywords: keywords) }
                continuation.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            operations.async { [self] in
                halt()
                continuation.resume()
            }
        }
    }

    /// ``stop()`` for synchronous callers, such as the app quitting. Waits for calls made before.
    public func stopNow() {
        operations.sync { halt() }
    }

    /// On `operations`.
    private func halt() {
        state.withLock { $0.request = nil }
        stopWaitingForPermission()
        stopListening()
        setStatus(.stopped)
    }

    public func status() async -> TextExpansionStatus {
        state.withLock { $0.status }
    }

    public func statusChanges() -> AsyncStream<TextExpansionStatus> {
        statuses.stream()
    }

    /// The keywords being watched.
    public var keywords: Set<String> {
        state.withLock { $0.buffer.keywords }
    }

    // MARK: Starting and stopping

    /// Starts listening when a request stands and every permission is there, or waits for the
    /// missing one. On `operations`.
    private func activate() -> TextExpansionStatus {
        guard state.withLock({ $0.request != nil }) else { return .stopped }
        if let missing = missingPermission() {
            stopListening()
            waitForPermission(missing)
            return setStatus(.needsPermission(missing))
        }
        stopWaitingForPermission()
        if !state.withLock({ $0.isListening }) {
            guard source.start({ [weak self] event in self?.receive(event) }) else {
                waitForPermission(.inputMonitoring)
                return setStatus(.needsPermission(.inputMonitoring))
            }
            state.withLock { state in
                state.isListening = true
                state.buffer.reset()
            }
            watchFocus()
        }
        return setStatus(currentRunningStatus())
    }

    private func stopListening() {
        let (wasListening, watch) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            defer {
                state.isListening = false
                state.focusWatch = nil
                state.buffer.reset()
            }
            return (state.isListening, state.focusWatch)
        }
        watch?.cancel()
        if wasListening { source.stop() }
    }

    private func missingPermission() -> Permission? {
        for permission in [Permission.inputMonitoring, .accessibility]
        where permissions.status(of: permission) != .granted {
            return permission
        }
        return nil
    }

    /// Keeps one permission stream open until the permission is granted, then starts. On
    /// `operations`.
    private func waitForPermission(_ permission: Permission) {
        guard state.withLock({ $0.waitingFor != permission }) else { return }
        stopWaitingForPermission()
        let changes = permissions.changes(of: permission)
        let wait = Task.detached { [weak self] in
            for await status in changes where status == .granted {
                guard let self, !Task.isCancelled else { return }
                self.operations.async {
                    self.state.withLock { $0.waitingFor = nil }
                    _ = self.activate()
                }
                return
            }
        }
        state.withLock { state in
            state.waitingFor = permission
            state.permissionWait = wait
        }
    }

    private func stopWaitingForPermission() {
        let wait = state.withLock { state -> Task<Void, Never>? in
            defer {
                state.waitingFor = nil
                state.permissionWait = nil
            }
            return state.permissionWait
        }
        wait?.cancel()
    }

    /// Resets the buffer whenever another app comes forward, and checks the permissions and secure
    /// input then.
    private func watchFocus() {
        let changes = focusChanges()
        let watch = Task.detached { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.receive(.focusChanged)
                if self.missingPermission() != nil {
                    self.operations.async { _ = self.activate() }
                }
            }
        }
        state.withLock { $0.focusWatch = watch }
    }

    // MARK: Status

    private func currentRunningStatus() -> TextExpansionStatus {
        let secure = secureInput.current()
        return secure.isOn ? .blockedBySecureInput(owner: secure.owner) : .running
    }

    /// Sets the status and tells the streams when it changed.
    @discardableResult private func setStatus(_ status: TextExpansionStatus) -> TextExpansionStatus {
        let changed = state.withLock { state -> Bool in
            defer { state.status = status }
            return state.status != status
        }
        if changed { statuses.send(status) }
        return status
    }

    /// Checks secure input again, now or after a delay, while listening.
    private func recheckSecureInput(after delay: Duration?) {
        guard let delay else {
            updateSecureInputStatus()
            return
        }
        let scheduled = state.withLock { state -> Bool in
            defer { state.secureCheckPending = true }
            return !state.secureCheckPending
        }
        guard scheduled else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay.timeInterval) { [weak self] in
            self?.state.withLock { $0.secureCheckPending = false }
            self?.updateSecureInputStatus()
        }
    }

    private func updateSecureInputStatus() {
        operations.async { [self] in
            guard state.withLock({ $0.isListening }) else { return }
            setStatus(currentRunningStatus())
        }
    }

    // MARK: Typing

    /// Takes one event from the source, on its thread.
    private func receive(_ event: TypingEvent) {
        let (match, request, blocked) = state.withLock {
            state -> (KeywordMatch?, Request?, Bool) in
            guard state.isListening, let request = state.request else { return (nil, nil, false) }
            let blocked: Bool =
                if case .blockedBySecureInput = state.status { true } else { false }
            return (state.buffer.handle(event), request, blocked)
        }
        switch event {
        case .click: recheckSecureInput(after: clickRecheckDelay)
        case .focusChanged: recheckSecureInput(after: nil)
        default: if blocked && event.isKey { recheckSecureInput(after: nil) }
        }
        guard let match, let request else { return }
        Task.detached { [self] in
            await expand(match, request: request)
        }
    }

    /// Asks the feature what the keyword becomes and types it.
    private func expand(_ match: KeywordMatch, request: Request) async {
        if let frontmost = frontmostBundleID(), request.options.excludedBundleIDs.contains(frontmost) {
            _ = state.withLock { $0.buffer.finish(match, with: .ignore) }
            return
        }
        let result = await request.expand(match.keyword)
        guard let plan = state.withLock({ $0.buffer.finish(match, with: result) }) else { return }
        do {
            try await poster.post(plan.keystrokes)
        } catch {
            // Accessibility went away: nothing was typed, and the next start reports it.
            return
        }
        if let command = plan.command, let runner = state.withLock({ $0.commandRunner }) {
            await runner(command, plan.arguments)
        }
    }
}
