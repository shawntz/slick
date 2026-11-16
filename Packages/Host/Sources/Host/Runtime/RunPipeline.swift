import Foundation
import Kit
import KitHosting

/// One pipeline for every command and action, whoever starts it: a key, the action panel, a hotkey,
/// a toast button or another command.
///
/// The steps, in order:
///
/// 1. Check ``Action/requires`` or ``Command/requires``. For a missing permission, show the
///    permission card; run only after the user granted it. A grant on the card tells the feature
///    through ``FeatureRuntime/permissionGranted(_:)``. When the system request does not grant
///    it, close the panel, say in a HUD what to allow in System Settings, open its pane unless the
///    system showed its own dialog, and wait, up to ``grantWait``, for the grant through the
///    permission's change stream. A grant made there ends the run without running it: whatever
///    app is in front now, perhaps System Settings, would get its paste or its keystrokes. A toast
///    says the permission is allowed and asks the user to run it again, and the feature hears of
///    the grant. A card asked while the panel was closed, as for a hotkey, a link or a keyword
///    typed in another app, opens the panel first.
/// 2. Ask the confirmation, unless the user suppressed it.
/// 3. Queue under the ``RunPolicy``: serial runs wait for the feature's earlier serial runs,
///    `dropWhileRunning` ignores a second start, `concurrent` runs at once.
/// 4. Run the handler in a task of its own. Closing the panel does not cancel it; turning the
///    feature off does.
/// 5. Map the outcome. A thrown error becomes a failure toast, or a HUD while the panel is closed;
///    `CancellationError` shows nothing. `needsPermission` shows the card and runs the handler once
///    more after a grant. `run` hands over to another command, passing undeclared arguments along,
///    and shows a failure toast when that command is unavailable.
@MainActor public final class RunPipeline {
    /// The panel. Without one, runs still happen but nothing is shown.
    public weak var presenter: (any RunPresenter)?
    /// Runs ignored under ``RunPolicy/dropWhileRunning``, as `<feature id>/command.<id>` or
    /// `<feature id>/action.<id>`. For tests.
    public private(set) var droppedRuns: [String] = []
    /// Errors handlers threw, newest last, at most 20. For the self-test and tests.
    public private(set) var recentErrors: [any Error] = []

    fileprivate weak var runtime: FeatureRuntime?
    private var serialTails: [String: Task<Void, Never>] = [:]
    private var running: Set<String> = []
    private var handlers: [String: [Int: Task<ActionOutcome, any Error>]] = [:]
    private var nextHandler = 0
    private var nextToast: UInt64 = 0
    /// The run waiting for each permission's grant. A newer run that waits for the same permission
    /// replaces it, so one grant runs one thing.
    private var grantWaits: [Permission: Task<Bool, Never>] = [:]

    /// How long a run whose permission request was denied waits for the user to grant it in System
    /// Settings.
    public static let grantWait: Duration = .seconds(300)
    /// Runs waiting for a permission grant in System Settings now. They do not count in
    /// ``activeRunCount``.
    public var grantWaitCount: Int { grantWaits.count }

    init(runtime: FeatureRuntime) {
        self.runtime = runtime
    }

    // MARK: Starting runs

    /// Runs a command by ID. Missing optional arguments get their defaults; arguments the command
    /// does not declare are passed along. An unknown or switched-off command shows a failure toast.
    /// A missing required argument is asked for in the search field, through
    /// ``RunPresenter/askForArguments(_:values:query:launch:)``, or shows a failure toast when the
    /// panel cannot ask. A link never runs a command that stays out of deep links.
    @discardableResult
    public func runCommand(
        _ id: ItemID, arguments: [String: String] = [:], query: String = "", launch: LaunchSource, row: Row? = nil
    ) -> Task<Void, Never> {
        runCommand(id, arguments: arguments, query: query, launch: launch, row: row, session: nil, startedByLink: false)
    }

    /// Runs a command for a run that started in `session`, as a hand-off does. A session that has
    /// ended does not open the panel to ask for arguments. A hand-off from a run a link started
    /// counts as started by a link too.
    private func runCommand(
        _ id: ItemID, arguments: [String: String], query: String, launch: LaunchSource, row: Row?, session: Int?,
        startedByLink: Bool
    ) -> Task<Void, Never> {
        guard let runtime, let entry = runtime.command(id), entry.isEnabled else {
            return Task { showFailure(title: HostStrings.commandUnavailable, message: nil) }
        }
        if launch == .deeplink, !entry.command.allowsDeepLinks {
            return Task { showFailure(title: HostStrings.commandRefusesLinks, message: nil) }
        }
        var values = arguments
        for argument in entry.command.arguments where (values[argument.name] ?? "").isEmpty {
            if let defaultValue = argument.defaultValue {
                values[argument.name] = defaultValue
            } else if !argument.isOptional {
                if let presenter, session.map({ $0 == presenter.sessionID && presenter.isPanelVisible }) ?? true,
                    presenter.askForArguments(entry, values: arguments, query: query, launch: launch)
                {
                    return Task {}
                }
                let message = HostStrings.missingArgument(argument.placeholder)
                return Task { showFailure(title: message, message: nil) }
            }
        }
        let command = entry.command
        var origin = RunOrigin(
            featureID: entry.featureID, feature: runtime.context(for: entry.featureID), query: query,
            arguments: CommandArguments(values), launch: launch, row: row)
        origin.commandTitle = command.title
        origin.startedByLink = startedByLink
        let request = RunRequest(
            key: "command." + command.id, title: command.title, requires: command.requires,
            confirmation: command.confirmation, isDestructive: command.confirmation?.isDestructive ?? false,
            policy: command.runPolicy, origin: origin, handler: command.run)
        return Task { await perform(request) }
    }

    /// Runs a command with text typed in root search, as a fallback or the Tab command does: the
    /// text arrives as the query and fills the first argument when the command declares one.
    @discardableResult
    public func runCommand(_ id: ItemID, typedText: String, launch: LaunchSource) -> Task<Void, Never> {
        var arguments: [String: String] = [:]
        if let first = runtime?.command(id)?.command.arguments.first { arguments[first.name] = typedText }
        return runCommand(id, arguments: arguments, query: typedText, launch: launch)
    }

    /// Runs an action. A submenu does nothing here; the action panel opens it. `arguments` are the
    /// values typed into a command row's argument chips, for that command's row actions.
    @discardableResult
    public func perform(
        _ action: Action, featureID: String, context: FeatureContext, query: String, launch: LaunchSource, row: Row?,
        arguments: CommandArguments = CommandArguments()
    ) -> Task<Void, Never> {
        guard case .run(let handler) = action.kind else { return Task {} }
        let origin = RunOrigin(
            featureID: featureID, feature: context, query: query, arguments: arguments, launch: launch, row: row)
        let request = RunRequest(
            key: "action." + action.id, title: action.title, requires: action.requires,
            confirmation: action.confirmation,
            isDestructive: action.style == .destructive || (action.confirmation?.isDestructive ?? false),
            policy: action.runPolicy, origin: origin, handler: handler)
        return Task { await perform(request) }
    }

    /// Runs a toast's button with the context of the run that showed the toast.
    @discardableResult
    public func perform(_ toastAction: ToastAction, origin: RunOrigin) -> Task<Void, Never> {
        let request = RunRequest(
            key: "toast", title: toastAction.title, requires: [], confirmation: nil, isDestructive: false,
            policy: .concurrent, origin: origin, handler: toastAction.run)
        return Task { await perform(request) }
    }

    /// Runs a handler the host made, such as a form's submit, through the same steps as an action:
    /// policy, task, outcome and errors. Serial with the feature's other runs.
    @discardableResult
    public func perform(key: String, origin: RunOrigin, handler: @escaping Action.Handler) -> Task<Void, Never> {
        let request = RunRequest(
            key: key, title: nil, requires: [], confirmation: nil, isDestructive: false, policy: .serial,
            origin: origin, handler: handler)
        return Task { await perform(request) }
    }

    /// Asks for each missing permission through the card, then the system, as a run does before
    /// its handler. True when all are granted on the card or by the system's own answer. A grant
    /// made in System Settings returns false, with a toast that asks the user to try again. A form
    /// calls it before validating.
    public func ensurePermissions(_ permissions: [Permission], featureID: String) async -> Bool {
        await grantMissing(permissions, featureID: featureID, title: nil) == .granted
    }

    /// The entries of a submenu, loaded with a context like the one its entries will run with.
    public func loadSubmenu(_ action: Action, origin: RunOrigin) async -> [Action] {
        guard case .submenu(let load) = action.kind, let permissions = runtime?.services.permissions else { return [] }
        let host = RunHost(pipeline: self, origin: origin, permissions: permissions)
        return await load(host.makeContext())
    }

    /// Cancels every running handler of a feature, as when it is turned off.
    public func cancelHandlers(of featureID: String) {
        for task in handlers[featureID, default: [:]].values { task.cancel() }
        serialTails[featureID] = nil
    }

    /// The number of handlers running now, for tests.
    public var runningHandlerCount: Int { handlers.values.reduce(0) { $0 + $1.count } }

    /// Runs started and not finished, from the moment they are asked for: waiting for permission,
    /// a confirmation or their turn, running, or applying their outcome.
    public private(set) var activeRunCount = 0

    // MARK: The steps

    private func perform(_ request: RunRequest) async {
        activeRunCount += 1
        defer { activeRunCount -= 1 }
        var request = request
        if let presenter, presenter.isPanelVisible { request.origin.session = presenter.sessionID }
        if request.origin.launch == .deeplink
            || request.origin.session.map({ presenter?.isLinkSession($0) ?? false }) == true
        {
            request.origin.startedByLink = true
        }
        guard
            await grantMissing(request.requires, featureID: request.origin.featureID, inRun: true, title: request.title)
                == .granted
        else { return }
        if let confirmation = request.confirmation {
            let suppressionKey = confirmation.suppressionKey.map { request.origin.featureID + "." + $0 }
            let suppressed = suppressionKey.map { runtime?.preferences.isConfirmationSuppressed($0) ?? false } ?? false
            if !suppressed {
                guard let presenter,
                    await presenter.confirm(
                        confirmation, isDestructive: request.isDestructive, suppressionKey: suppressionKey)
                else { return }
            }
        }
        guard let permissions = runtime?.services.permissions else { return }
        let host = RunHost(pipeline: self, origin: request.origin, permissions: permissions)
        guard var outcome = await execute(request, host: host) else { return }
        if case .needsPermission(let permission) = outcome {
            guard
                await grantMissing(
                    [permission], featureID: request.origin.featureID, force: true, inRun: true, title: request.title)
                    == .granted,
                let again = await execute(request, host: host)
            else { return }
            outcome = again
        }
        // A feature switched off while its handler ran: the handler ignored the cancellation.
        // Nothing it asks for happens.
        if let feature = runtime?.feature(request.origin.featureID), !feature.isEnabled { return }
        switch outcome {
        case .keepOpen:
            break
        case .run(let id, let arguments):
            await runCommand(
                id, arguments: arguments, query: "", launch: .command, row: nil, session: request.origin.session,
                startedByLink: request.origin.startedByLink
            ).value
        case .needsPermission(let permission):
            // Asked twice in a row: the grant did not take. Say so instead of looping.
            showFailure(title: HostStrings.permissionStillMissing(permission.displayName), message: nil)
        default:
            presenter?.apply(outcome, origin: request.origin)
        }
        if host.reloadRequested { presenter?.reloadTopPage() }
    }

    /// Runs the handler under its policy. Nil when the run was dropped, cancelled or failed.
    private func execute(_ request: RunRequest, host: RunHost) async -> ActionOutcome? {
        let featureID = request.origin.featureID
        let context = host.makeContext()
        let handler = request.handler
        let task: Task<ActionOutcome, any Error>
        switch request.policy {
        case .concurrent:
            task = Task { try await handler(context) }
        case .dropWhileRunning:
            let key = featureID + "/" + request.key
            guard running.insert(key).inserted else {
                droppedRuns.append(key)
                return nil
            }
            defer { running.remove(key) }
            return await track(Task { try await handler(context) }, featureID: featureID)
        case .serial:
            let previous = serialTails[featureID]
            task = Task {
                await previous?.value
                try Task.checkCancellation()
                return try await handler(context)
            }
            serialTails[featureID] = Task { _ = try? await task.value }
        }
        return await track(task, featureID: featureID)
    }

    private func track(_ task: Task<ActionOutcome, any Error>, featureID: String) async -> ActionOutcome? {
        nextHandler += 1
        let token = nextHandler
        handlers[featureID, default: [:]][token] = task
        defer { handlers[featureID]?[token] = nil }
        do {
            return try await task.value
        } catch is CancellationError {
            return nil
        } catch {
            recentErrors.append(error)
            if recentErrors.count > 20 { recentErrors.removeFirst() }
            let described = error as? any LocalizedError
            showFailure(
                title: described?.errorDescription ?? String(describing: error), message: described?.failureReason)
            return nil
        }
    }

    /// How asking for permissions ended.
    enum GrantOutcome: Equatable {
        /// Every permission is granted: the run goes on.
        case granted
        /// The user said no, or the wait ran out: the run ends quietly.
        case refused
        /// The user granted one in System Settings: the run ends, and a toast asks to run it again.
        case grantedInSettings
    }

    /// Asks for each missing permission through the card, then the system. With `force`, asks
    /// even when the status already reads granted, as for a handler that found one missing.
    /// `inRun` says the caller counts in ``activeRunCount``, which a wait for a grant in System
    /// Settings leaves. `title` names the run in the toast after such a grant.
    private func grantMissing(
        _ permissions: [Permission], featureID: String, force: Bool = false, inRun: Bool = false, title: String?
    ) async -> GrantOutcome {
        guard let runtime else { return .refused }
        let service = runtime.services.permissions
        for permission in permissions where force || !service.status(of: permission).isGranted {
            let manifest = runtime.feature(featureID)?.manifest
            let reason = manifest?.permissions.first { $0.permission == permission }?.reason ?? ""
            guard let presenter,
                await presenter.askForPermission(
                    permission, featureName: manifest?.name ?? HostStrings.appName, reason: reason)
            else { return .refused }
            let before = service.status(of: permission)
            let after = await service.request(permission)
            if after.isGranted {
                await runtime.permissionGranted(permission)
                continue
            }
            // Listen before opening System Settings, so a quick grant is not missed.
            let changes = service.changes(of: permission)
            // System Settings or the system's dialog takes key focus, and the panel would close with
            // its toast unread. Close it first, so the HUD says what to do there.
            if presenter.isPanelVisible { presenter.dismissPanel() }
            if !Self.systemAskedItself(permission, before: before, after: after) {
                await service.openSettings(for: permission)
            }
            showFailure(title: HostStrings.grantInSettings(permission.displayName), message: nil)
            guard await waitForGrant(permission, changes: changes, inRun: inRun) else { return .refused }
            await runtime.permissionGranted(permission)
            // The run ends here. Running it again asks for any other permission it lacks.
            showSuccess(title: HostStrings.grantedRunAgain(permission.displayName, run: title))
            return .grantedInSettings
        }
        return .granted
    }

    /// True when the request showed the system's own dialog, so Host opens no pane beside it.
    /// Accessibility, Input Monitoring and Screen Recording show a dialog with a button to System
    /// Settings the first time they are asked, and the request returns before the user answers. A
    /// permission that waits for the answer, such as Calendars, showed its dialog when the answer
    /// is not "not determined" any more; an Automation target that is not installed shows nothing.
    /// Full Disk Access and Paste from Other Apps have no dialog. Once asked, a permission shows
    /// nothing again, and its status reads denied.
    public nonisolated static func systemAskedItself(
        _ permission: Permission, before: PermissionStatus, after: PermissionStatus
    ) -> Bool {
        guard before == .notDetermined else { return false }
        switch permission {
        case .accessibility, .inputMonitoring, .screenRecording: return true
        case .fullDiskAccess, .pasteboard: return false
        default: return after != .notDetermined
        }
    }

    /// Waits until the permission's change stream reports it granted, for at most ``grantWait``.
    /// False when the time ran out, the run was cancelled, or a newer run started waiting for the
    /// same permission. The wait does not count as an active run.
    private func waitForGrant(
        _ permission: Permission, changes: AsyncStream<PermissionStatus>, inRun: Bool
    ) async -> Bool {
        guard let runtime else { return false }
        if runtime.services.permissions.status(of: permission).isGranted { return true }
        grantWaits[permission]?.cancel()
        let clock = runtime.services.clock
        let wait = Task { () -> Bool in
            for await status in changes where status.isGranted { return true }
            return false
        }
        grantWaits[permission] = wait
        let timer = Task {
            do {
                try await clock.sleep(for: Self.grantWait)
                wait.cancel()
            } catch {}
        }
        if inRun { activeRunCount -= 1 }
        let granted = await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        if inRun { activeRunCount += 1 }
        timer.cancel()
        if grantWaits[permission] == wait { grantWaits[permission] = nil }
        return granted
    }

    // MARK: Feedback

    /// Shows a failure toast, or a HUD while the panel is closed.
    func showFailure(title: String, message: String?) {
        guard let presenter else { return }
        if presenter.isPanelVisible {
            presenter.showToast(.failure(title, message: message), id: makeToastID(), origin: nil)
        } else {
            presenter.showHUD(.failure(title))
        }
    }

    /// Shows a success toast, or a HUD while the panel is closed.
    func showSuccess(title: String) {
        guard let presenter else { return }
        if presenter.isPanelVisible {
            presenter.showToast(.success(title), id: makeToastID(), origin: nil)
        } else {
            presenter.showHUD(.success(title))
        }
    }

    /// A toast ID from the top of the range, apart from the IDs `ActionContext` hands out.
    func makeToastID() -> ToastID {
        nextToast += 1
        return ToastID(UInt64.max - nextToast)
    }

}

/// One run, as the pipeline queues it.
struct RunRequest {
    /// `command.<id>` or `action.<id>`, for `dropWhileRunning`.
    var key: String
    /// The command's or action's title, for the toast that asks to run it again. Nil for a run the
    /// host made, such as a form's submit.
    var title: String?
    var requires: [Permission]
    var confirmation: Confirmation?
    var isDestructive: Bool
    var policy: RunPolicy
    var origin: RunOrigin
    var handler: Action.Handler
}

/// The panel as one run's handler sees it. It forwards to the presenter and remembers whether the
/// handler asked for a reload, so the page loads once, after the outcome.
@MainActor final class RunHost: ActionHost {
    private weak var pipeline: RunPipeline?
    let origin: RunOrigin
    /// The context the handler gets: the origin's, or for a run a link started the same context
    /// with a pasteboard that copies instead of pasting.
    let feature: FeatureContext
    private let permissions: any PermissionService
    private(set) var reloadRequested = false

    init(pipeline: RunPipeline, origin: RunOrigin, permissions: any PermissionService) {
        self.pipeline = pipeline
        self.origin = origin
        self.permissions = permissions
        if origin.startedByLink, let runtime = pipeline.runtime {
            var services = runtime.services
            services.pasteboard = LinkPasteboard(wrapping: services.pasteboard)
            feature = FeatureContext(
                featureID: origin.feature.featureID, environment: origin.feature.environment, services: services)
        } else {
            feature = origin.feature
        }
    }

    func makeContext() -> ActionContext {
        ActionContext(
            feature: feature, host: self, query: origin.query, arguments: origin.arguments, launch: origin.launch,
            row: origin.row)
    }

    private var presenter: (any RunPresenter)? { pipeline?.presenter }

    func showToast(_ toast: Toast, id: ToastID) {
        presenter?.showToast(toast, id: id, origin: origin)
    }

    func dismissToast(_ id: ToastID) {
        presenter?.dismissToast(id)
    }

    func reload() {
        reloadRequested = true
    }

    func setQuery(_ text: String) {
        presenter?.setQuery(text)
    }

    func requestPermission(_ permission: Permission) async -> PermissionStatus {
        await permissions.request(permission)
    }

    func quickLook(_ urls: [URL]) {
        presenter?.quickLook(urls)
    }

    func share(_ items: [ShareItem]) {
        presenter?.share(items)
    }

    /// A feature's own question, such as one that names what it will delete. A stored "Don't ask
    /// again" answers yes without asking, as it does for a declared confirmation.
    func confirm(_ confirmation: Confirmation) async -> Bool {
        let key = confirmation.suppressionKey.map { origin.featureID + "." + $0 }
        if let key, pipeline?.runtime?.preferences.isConfirmationSuppressed(key) == true { return true }
        guard let presenter else { return false }
        return await presenter.confirm(confirmation, isDestructive: confirmation.isDestructive, suppressionKey: key)
    }

    func dismiss() {
        presenter?.dismissPanel()
    }
}
