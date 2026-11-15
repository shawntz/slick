import Foundation
import Kit
import Synchronization

/// The live text expansion service: a ``TypingBuffer`` fed by a ``KeyEventSource``, typing through
/// a ``KeystrokePoster``.
///
/// - ``start(keywords:options:expand:)`` never prompts. Without Input Monitoring or Accessibility
///   it returns ``TextExpansionStatus/needsPermission(_:)``, creates no tap, and keeps one
///   permission stream open until the user grants it; then it starts by itself and
///   ``statusChanges()`` reports `.running`. While it waits, it also tries again each time
///   another app comes forward, which covers a tap macOS refused while the permission reads
///   granted.
/// - ``statusChanges()`` reports every start and stop, even one that leaves the status as it was,
///   and every change a permission or secure input makes. A permission taken away while running
///   is found when another app comes forward, or at once when typing an expansion fails.
/// - Start, stop and keyword updates run one at a time on a serial queue, never on the caller's
///   thread, in the order they are called, so the last start or stop wins. Creating the tap and
///   checking the permissions can wait on the system for milliseconds.
/// - When a keyword is typed, the feature's handler decides. An insert deletes the keyword and
///   types the text, then presses Left for the characters after the cursor. A command deletes the
///   keyword, then hands the run to the runner the host sets with ``setCommandRunner(_:)``.
///   Nothing expands while an excluded app is frontmost.
/// - Secure input is checked when typing starts, when another app comes forward, shortly after a
///   click, on every modifier key, and on the first key after it was seen on, so no timer runs
///   while the user is idle.
/// - Typing into this app's own windows, such as the launcher's search field, never expands and
///   is forgotten, so it cannot complete a keyword in the app that comes next.
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
    private let ownAppIsKey: @Sendable () -> Bool
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
    ///   - focusChanges: A stream that yields when another app comes forward, or when key focus
    ///     enters or leaves this app's windows.
    ///   - ownAppIsKey: True while one of this app's windows has key focus, so typing goes to
    ///     this app.
    public init(
        permissions: any PermissionService,
        source: any KeyEventSource,
        poster: any KeystrokePoster,
        secureInput: any SecureInputReader,
        frontmostBundleID: @escaping @Sendable () -> String? = { nil },
        focusChanges: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
        clickRecheckDelay: Duration = .milliseconds(300),
        ownAppIsKey: @escaping @Sendable () -> Bool = { false }
    ) {
        self.permissions = permissions
        self.source = source
        self.poster = poster
        self.secureInput = secureInput
        self.frontmostBundleID = frontmostBundleID
        self.focusChanges = focusChanges
        self.clickRecheckDelay = clickRecheckDelay
        self.ownAppIsKey = ownAppIsKey
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
                continuation.resume(returning: activate(reportingUnchanged: true))
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
        setStatus(.stopped, reportingUnchanged: true)
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
    /// missing one. On `operations`. A start reports its status even when it did not change.
    private func activate(reportingUnchanged: Bool = false) -> TextExpansionStatus {
        guard state.withLock({ $0.request != nil }) else { return .stopped }
        if let missing = missingPermission() {
            return waitAfterLosing(missing, reportingUnchanged: reportingUnchanged)
        }
        stopWaitingForPermission()
        if !state.withLock({ $0.isListening }) {
            guard source.start({ [weak self] event in self?.receive(event) }) else {
                return waitAfterLosing(.inputMonitoring, reportingUnchanged: reportingUnchanged)
            }
            state.withLock { state in
                state.isListening = true
                state.buffer.reset()
            }
            watchFocus()
        }
        return setStatus(currentRunningStatus(), reportingUnchanged: reportingUnchanged)
    }

    /// Stops listening and waits for the permission. On `operations`.
    @discardableResult private func waitAfterLosing(
        _ permission: Permission, reportingUnchanged: Bool = false
    ) -> TextExpansionStatus {
        stopListening()
        waitForPermission(permission)
        return setStatus(.needsPermission(permission), reportingUnchanged: reportingUnchanged)
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

    /// Keeps one permission stream open until the permission is granted, then starts. Another app
    /// coming forward also tries again, because a tap can fail while the permission reads granted,
    /// and then the stream never changes. On `operations`.
    private func waitForPermission(_ permission: Permission) {
        guard state.withLock({ $0.waitingFor != permission }) else { return }
        stopWaitingForPermission()
        let changes = permissions.changes(of: permission)
        let focus = focusChanges()
        let wait = Task.detached { [weak self] in
            // True when the grant came or another app came forward; false when both streams
            // ended without either, such as a focus stream that never yields, or a cancel.
            let woke = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    for await status in changes where status == .granted { return true }
                    return false
                }
                group.addTask {
                    for await _ in focus { return true }
                    return false
                }
                for await woke in group where woke {
                    group.cancelAll()
                    return true
                }
                return false
            }
            guard woke, let self, !Task.isCancelled else { return }
            self.operations.async {
                // A newer wait or a stop may have replaced this one meanwhile.
                guard self.state.withLock({ $0.waitingFor == permission }) else { return }
                self.state.withLock { $0.waitingFor = nil }
                _ = self.activate()
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

    /// Sets the status and tells the streams when it changed, or always with `reportingUnchanged`.
    @discardableResult private func setStatus(
        _ status: TextExpansionStatus, reportingUnchanged: Bool = false
    ) -> TextExpansionStatus {
        let changed = state.withLock { state -> Bool in
            defer { state.status = status }
            return state.status != status
        }
        if changed || reportingUnchanged { statuses.send(status) }
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
        if event.isKey, ownAppIsKey() {
            // Typing in this app's own window. Never expand there, and forget it, so it cannot
            // complete a keyword in the app that comes next.
            state.withLock { $0.buffer.reset() }
            return
        }
        let (match, request, blocked) = state.withLock {
            state -> (KeywordMatch?, Request?, Bool) in
            guard state.isListening, let request = state.request else { return (nil, nil, false) }
            let blocked: Bool =
                if case .blockedBySecureInput = state.status { true } else { false }
            return (state.buffer.handle(event), request, blocked)
        }
        switch event {
        case .click: recheckSecureInput(after: clickRecheckDelay)
        case .focusChanged, .modifiers: recheckSecureInput(after: nil)
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
            // Accessibility went away: nothing was typed. Say so now and wait for it.
            operations.async { [self] in
                guard state.withLock({ $0.request != nil && $0.isListening }) else { return }
                waitAfterLosing(.accessibility)
            }
            return
        }
        if let command = plan.command, let runner = state.withLock({ $0.commandRunner }) {
            await runner(command, plan.arguments)
        }
    }
}
