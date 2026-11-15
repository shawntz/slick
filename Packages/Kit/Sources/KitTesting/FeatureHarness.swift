import Foundation
import Kit

/// Builds a feature against ``FakeServices`` and drives it the way the host would, with no window:
/// run commands, open pages, type queries, select rows, run actions, submit forms, ask root search
/// inputs, and read what the fakes recorded.
///
/// ```swift
/// let harness = FeatureHarness(EmojiFeature.self)
/// try await harness.run("search-emoji")
/// try await harness.setQuery("smile")
/// try harness.select(title: "Smiling Face")
/// try await harness.performPrimary()
/// #expect(harness.fakes.pasteboard.pastedTexts == ["😊"])
/// ```
///
/// It follows the host's rules where they matter to a feature: host filtering through the fuzzy
/// index, section visibility and rank hints, the first row selected after a load, required
/// permissions checked before anything runs, confirmations asked, required form fields checked
/// before `validate`, runs serialized by ``RunPolicy``, actions hidden when the command they hand
/// work to is unavailable, toasts drawn as HUDs while the panel is closed, and a page loaded again
/// after an action when it called ``ActionContext/reload()``, when its source's ``ChangeSignal``
/// fired, or when a setting it reloads on changed. Debounces are skipped: each query loads at once.
///
/// Background work started by the feature is not awaited by itself. Call ``settle()`` after a fake
/// played something, such as ``FakePasteboard/simulateCopy(_:from:)``, or ``waitForChange()`` to
/// wait for the page's source to signal.
@MainActor public final class FeatureHarness<F: Feature>: ActionHost {
    public let fakes: FakeServices
    public let context: FeatureContext
    public let feature: F

    /// What ``ActionContext/confirm(_:)`` and declared confirmations answer. Default true.
    public var confirmationAnswer = true
    /// When true, a missing permission is requested from the fake permission center, as if the user
    /// pressed "Grant" on the host's card, and the action runs if it was granted. When false (the
    /// default), the call throws ``HarnessError/permissionRequired(_:)``.
    public var grantsMissingPermissions = false
    /// When true (the default), an error a handler throws is rethrown to the test. When false, the
    /// harness does what the host does: it records the error in ``actionErrors`` and shows a failure
    /// toast, or a HUD while the panel is closed.
    public var throwsActionErrors = true
    /// Commands the host would report unavailable, such as another feature's that is off. Actions
    /// whose ``Action/requiresCommand`` is here are hidden, and running one shows a failure toast.
    public var unavailableCommands: Set<ItemID> = []

    /// Every toast shown or updated while the panel was visible, in order.
    public internal(set) var toasts: [Toast] = []
    /// The toast showing now, if any.
    public internal(set) var visibleToast: Toast?
    /// Every HUD: from ``ActionOutcome/close(hud:)``, and toasts shown while the panel was closed.
    public internal(set) var huds: [HUD] = []
    /// True while the panel is closed: after an outcome closed it, after
    /// ``ActionContext/dismiss()``, or during a command started by a hotkey.
    public internal(set) var isClosed = false
    public internal(set) var queryChanges: [String] = []
    public internal(set) var quickLooks: [[URL]] = []
    public internal(set) var shares: [[ShareItem]] = []
    /// Every confirmation asked, declared or from ``ActionContext/confirm(_:)``.
    public internal(set) var confirmations: [Confirmation] = []
    /// Every ``ActionOutcome/run(_:arguments:)``. The feature's own commands also run.
    public internal(set) var commandRuns: [CommandRun] = []
    /// The query of every ``ActionOutcome/showRoot(query:)``.
    public internal(set) var rootQueries: [String] = []
    /// Errors handlers threw while ``throwsActionErrors`` was false.
    public internal(set) var actionErrors: [any Error] = []
    /// Runs ignored under ``RunPolicy/dropWhileRunning``, as `command.<id>` or `action.<id>`.
    public internal(set) var droppedRuns: [String] = []
    /// The page stack, bottom first. Empty means root search.
    public internal(set) var pages: [PageState] = []

    var reloadRequested = false
    var queryChangedByAction = false
    var visibleToastID: ToastID?
    var seenIssues: [FeatureIssue] = []
    var serialTail: Task<Void, Never>?
    var running: Set<String> = []

    /// Makes the feature with ``Feature/init(context:)`` over the fakes. To give the feature a test
    /// double of its own service, call `fakes.override(_:with:)` first.
    public convenience init(
        _ type: F.Type = F.self, environment: RunEnvironment = .selftest, fakes: FakeServices = FakeServices()
    ) {
        self.init(environment: environment, fakes: fakes) { F(context: $0) }
    }

    /// Makes the feature with a closure, for a feature made with dependencies of its own.
    public init(
        environment: RunEnvironment = .selftest, fakes: FakeServices = FakeServices(), make: (FeatureContext) -> F
    ) {
        self.fakes = fakes
        self.context = fakes.context(featureID: F.manifest.id, environment: environment)
        self.feature = make(context)
    }

    /// Problems with what the feature declares, plus problems with every action list and form the
    /// harness has handed out so far. A test should expect this to be empty.
    public var issues: [FeatureIssue] { FeatureValidator.validate(feature) + seenIssues }

    public func activate() async {
        await feature.activate()
    }

    public func deactivate() async {
        await feature.deactivate()
    }

    /// Waits until the feature's background loops have handled everything the fakes sent them (see
    /// ``FakeServices/settle()``), then loads the top page again if its source changed meanwhile.
    public func settle() async throws {
        await fakes.settle()
        if let state = page, isStale(state) { try await load(state, reason: .reload) }
    }

    /// Waits for the top page's source to change, through its ``ListSource/changes`` signal or a
    /// setting in ``ListSource/reloadsOnSettings``, then loads the page again. Returns at once when
    /// it already changed since the last load.
    public func waitForChange() async throws {
        guard let state = page, let source = state.listSource else { throw HarnessError.wrongPage(expected: "list") }
        let names = Set(source.reloadsOnSettings.map { context.settings.storageName(for: $0.name) })
        guard source.changes != nil || !names.isEmpty else { throw HarnessError.pageCannotChange }
        let signal = source.changes?.stream()
        let settingChanges = names.isEmpty ? nil : fakes.settings.changes(for: names)
        let alreadyChanged = isStale(state)
        await withTaskGroup(of: Void.self) { group in
            if let signal { group.addTask { for await _ in signal { return } } }
            if let settingChanges { group.addTask { for await _ in settingChanges { return } } }
            if !alreadyChanged { await group.next() }
            group.cancelAll()
        }
        try await load(state, reason: .reload)
    }

    // MARK: - Commands

    /// The feature's command with this ID.
    public func command(_ id: String) throws -> Command {
        guard let command = feature.commands.first(where: { $0.id == id }) else { throw HarnessError.noSuchCommand(id) }
        return command
    }

    /// Runs a command and applies its outcome. Missing optional arguments get their defaults; a
    /// missing required one throws. Arguments the command does not declare are passed along.
    @discardableResult
    public func run(
        _ commandID: String, arguments: [String: String] = [:], query: String = "", launch: LaunchSource = .root
    ) async throws -> ActionOutcome {
        let command = try command(commandID)
        isClosed = launch == .hotkey
        try await checkPermissions(command.requires)
        var values = arguments
        for argument in command.arguments where (values[argument.name] ?? "").isEmpty {
            if let defaultValue = argument.defaultValue {
                values[argument.name] = defaultValue
            } else if !argument.isOptional {
                throw HarnessError.missingArgument(argument.name)
            }
        }
        let actionContext = makeContext(query: query, arguments: CommandArguments(values), launch: launch, row: nil)
        return try await execute(
            requires: [], confirmation: command.confirmation, policy: command.runPolicy, key: "command." + command.id,
            context: actionContext, handler: command.run)
    }

    /// Runs a command from the fallback list with the text typed in root search, which arrives as
    /// the query and fills the first argument when the command declares one.
    @discardableResult
    public func runFallback(_ commandID: String, text: String) async throws -> ActionOutcome {
        try await runWithTypedText(try command(commandID), text: text, launch: .fallback)
    }

    /// Presses Tab in root search with this query: the selected row's completion wins and becomes
    /// the new query, which is returned; otherwise the feature's Tab command runs with the text and
    /// nil is returned.
    @discardableResult
    public func pressTab(_ query: String, on row: Row? = nil) async throws -> String? {
        if let completion = row?.completion { return completion }
        guard let command = feature.commands.first(where: \.takesRootQueryOnTab) else { return nil }
        try await runWithTypedText(command, text: query, launch: .tabFromRoot)
        return nil
    }

    /// The actions a command's row offers in root search after Run, from ``Command/rowActions``.
    public func rowActions(ofCommand commandID: String) throws -> [Action] {
        shown(try command(commandID).rowActions?() ?? [])
    }

    /// Presses a button in the feature's settings pane, asking its confirmation first. Its toasts are
    /// recorded in ``toasts``, as the settings window shows them, whether or not the panel is closed.
    public func pressSettingsButton(_ title: String) async throws {
        let items = feature.settingsPane?.sections.flatMap(\.items) ?? []
        guard let item = items.first(where: { $0.title == title }),
            case .button(_, let confirmation, let run) = item.control
        else {
            throw HarnessError.noSuchSettingsButton(title)
        }
        let panelWasClosed = isClosed
        isClosed = false
        defer { isClosed = panelWasClosed }
        try await execute(
            requires: [], confirmation: confirmation, policy: .serial, key: "settings." + title,
            context: makeContext(query: "", launch: .settings, row: nil)
        ) { context in
            try await run(context)
            return .keepOpen
        }
    }

    /// Presses the button on the toast showing now.
    @discardableResult
    public func performToastAction() async throws -> ActionOutcome {
        guard let action = visibleToast?.action else { throw HarnessError.noToastAction }
        return try await execute(
            requires: [], confirmation: nil, policy: .concurrent, key: "toast",
            context: makeContext(query: page?.query ?? "", launch: .page, row: selectedRow), handler: action.run)
    }

    @discardableResult
    private func runWithTypedText(_ command: Command, text: String, launch: LaunchSource) async throws
        -> ActionOutcome
    {
        var arguments: [String: String] = [:]
        if let first = command.arguments.first { arguments[first.name] = text }
        return try await run(command.id, arguments: arguments, query: text, launch: launch)
    }

    // MARK: - ActionHost

    public func showToast(_ toast: Toast, id: ToastID) {
        if isClosed {
            huds.append(HUD(toast.title, style: toast.style))
            return
        }
        toasts.append(toast)
        visibleToast = toast
        visibleToastID = id
    }

    public func dismissToast(_ id: ToastID) {
        guard visibleToastID == id else { return }
        visibleToast = nil
        visibleToastID = nil
    }

    public func reload() {
        reloadRequested = true
    }

    public func setQuery(_ text: String) {
        queryChanges.append(text)
        guard let page else { return }
        page.query = text
        queryChangedByAction = true
    }

    public func requestPermission(_ permission: Permission) async -> PermissionStatus {
        await fakes.permissions.request(permission)
    }

    public func quickLook(_ urls: [URL]) {
        quickLooks.append(urls)
    }

    public func share(_ items: [ShareItem]) {
        shares.append(items)
    }

    public func confirm(_ confirmation: Confirmation) async -> Bool {
        confirmations.append(confirmation)
        return confirmationAnswer
    }

    public func dismiss() {
        isClosed = true
        visibleToast = nil
        visibleToastID = nil
    }
}
