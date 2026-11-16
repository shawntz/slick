import AppKit
import Kit
import KitHosting
import LauncherUI

/// The launcher panel: LauncherUI's surface and summoner, a navigation stack with root search at
/// the bottom, the keyboard model, the action panel, in-panel cards, toasts and HUDs.
///
/// The summon path changes visibility and key status and calls ``RootSource/begin()``, and draws
/// only when Root's prepared empty state changed since the last dismiss. Everything else is
/// prepared at dismiss: the stack returns to root after the `resetToRootAfter` setting, the query
/// clears and the last empty state is drawn again.
///
/// ```swift
/// let panel = PanelController(runtime: runtime, rootSource: root, icons: icons, themes: themes)
/// panel.prewarm()
/// // on the launcher hotkey:
/// panel.toggle(eventTimestamp: event.timestamp)
/// ```
@MainActor public final class PanelController: PageHost {
    public let runtime: FeatureRuntime
    public let rootSource: any RootSource
    public let surface: LauncherSurface
    /// Shows and hides the panel. Replaced, while the panel is hidden, when the summon strategy
    /// setting changes.
    public private(set) var summoner: Summoner
    public let rowMapper: RowMapper
    public let rootPage: RootPageController
    /// The one action card, reused and prewarmed.
    public let actionCard = ActionCardView(
        content: ActionCardContent(sections: [], placeholder: HostStrings.actionSearchPlaceholder))
    /// The navigation stack, root search first.
    public private(set) var stack: [any PageController]

    /// Opens the settings window, for Command-comma. App sets it.
    public var onOpenSettings: (() -> Void)?
    /// Replaces the in-panel Quick Look page when set.
    public var onQuickLook: (([URL]) -> Void)?
    /// Replaces the in-panel share menu when set.
    public var onShare: (([ShareItem]) -> Void)?
    /// The services the share menu offers. The system's in the live app; nil elsewhere, where the
    /// menu says sharing is not available. Tests and scenarios pass a fake.
    public var shareSheet: (any ShareSheet)?
    /// Makes the view Quick Look shows a file in. Tests replace it.
    public var makePreviewView: @MainActor (URL) -> NSView = { QuickLookPageController.quickLookView(for: $0) }
    /// Changes every time the panel opens.
    public private(set) var sessionID = 0
    /// The last panel session a link opened or reached. Runs that start in it copy instead of
    /// pasting: see ``RunOrigin/startedByLink``.
    public private(set) var linkSession: Int?
    /// The page a link pushed last, such as the page that asks before a link runs a command. While
    /// it is on top, going back to root returns to the page under it.
    public private(set) weak var linkPage: (any PageController)?

    /// The entries the action panel shows now, in order.
    public internal(set) var actionEntries: [ActionEntry] = []
    /// What the action panel acts on now.
    public internal(set) var actionTarget: ActionTarget?

    let hud: any HUDDisplay
    /// Where Large Type goes: a window in the live launcher, a record everywhere else.
    public let largeType: any LargeTypeDisplay
    /// The text Large Type showed last, for scenarios and tests.
    public private(set) var lastLargeType: String?
    let toasts: ToastController
    let general: FeatureSettings
    private let themes: ThemeStore?
    private var baseTheme: Theme
    private var themeObserver: ThemeStore.ObserverID?
    private var watchers: [Task<Void, Never>] = []
    private var resetTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var hasPrewarmed = false
    var pendingAnswer: PendingAnswer?
    /// The command whose argument chips show in the search field.
    private(set) var chipsCommand: ItemID?

    /// - Parameters:
    ///   - runtime: The feature runtime. The panel becomes its pipeline's presenter.
    ///   - rootSource: Root search.
    ///   - icons: Icon lookups.
    ///   - themes: The theme store; nil keeps the standard theme.
    ///   - surface: The surface to drive. Tests pass one placed off screen.
    ///   - hud: Where HUDs go. Tests pass a recorder.
    ///   - largeType: Where Large Type goes. By default a window in the live environment, and a
    ///     ``RecordingLargeType`` in every other, so nothing shows in a scenario, the self-test or
    ///     a benchmark.
    public init(
        runtime: FeatureRuntime, rootSource: any RootSource, icons: any IconProvider, themes: ThemeStore? = nil,
        surface: LauncherSurface? = nil, hud: (any HUDDisplay)? = nil, largeType: (any LargeTypeDisplay)? = nil
    ) {
        self.runtime = runtime
        self.rootSource = rootSource
        self.themes = themes
        general = HostSettings.settings(runtime.services.settings)
        baseTheme = themes?.current ?? surface?.theme ?? .standard
        let surface = surface ?? LauncherSurface(theme: baseTheme)
        self.surface = surface
        summoner = Summoner(surface: surface, strategy: Self.strategy(general))
        rowMapper = RowMapper(icons: icons, clock: runtime.services.clock)
        shareSheet = runtime.environment.touchesRealSystem ? SystemShareSheet() : nil
        let hud = hud ?? HUDWindowDisplay(theme: baseTheme)
        self.hud = hud
        self.largeType =
            largeType
            ?? (runtime.environment.touchesRealSystem
                ? LargeTypeWindowDisplay(theme: baseTheme) : RecordingLargeType())
        toasts = ToastController(actionBar: surface.actionBar, hud: hud)
        rootPage = RootPageController(source: rootSource, runtime: runtime)
        stack = [rootPage]

        runtime.pipeline.presenter = self
        runtime.rootSource = rootSource
        surface.queryField.delegate = self
        summoner.prepareNext = { [weak self] in self?.didDismiss() }
        actionCard.onActivate = { [weak self] item in self?.activateCardItem(item) }
        surface.actionBar.onToastButton = { [weak self] in self?.runToastAction() }
        let themeName = general[HostSettings.themeName]
        if let themes, themes.selectedName != themeName { themes.select(themeName) }
        applyTheme()
        rootPage.showsCompletion = general[HostSettings.inlineCompletion]
        configure(rootPage)
        showTop(animated: false)
        rootPage.pageDidAppear(in: self)
        startWatching()
    }

    isolated deinit {
        for watcher in watchers { watcher.cancel() }
        if let themeObserver { themes?.removeObserver(themeObserver) }
    }

    /// The page on top.
    public var top: any PageController { stack[stack.count - 1] }

    /// The panel's latency probe.
    public var probe: LatencyProbe { summoner.probe }

    /// Measures the CPU spent in Root and LauncherUI calls, for benches. Off by default.
    public let workMeter = WorkMeter()

    public var resolvedTheme: ResolvedTheme { surface.resolvedTheme }

    /// Renders the panel, the action card and the HUD once while hidden, and draws root search's
    /// empty state, so the first summon costs what later ones do. Call once at launch.
    public func prewarm() {
        hasPrewarmed = true
        summoner.prewarm()
        surface.prewarm(actionCard)
        hud.prewarm()
        rootPage.beginSession()
        rootPage.endSession()
    }

    // MARK: Summon and dismiss

    /// True while the panel is on screen.
    public var isPanelVisible: Bool { summoner.isShown }

    /// Shows the panel. Only visibility, key status and ``RootSource/begin()`` happen here. A
    /// pushed page on top hears ``PageController/panelDidShow()`` on the next turn, so it reloads
    /// off the summon path.
    public func summon(eventTimestamp: TimeInterval? = nil) {
        guard !summoner.isShown else { return }
        resetTask?.cancel()
        resetTask = nil
        sessionID += 1
        if top === rootPage { rootPage.beginSession() }
        summoner.summon(eventTimestamp: eventTimestamp)
        if top !== rootPage {
            showTask = Task { [weak self] in
                guard let self, summoner.isShown else { return }
                showTask = nil
                top.panelDidShow()
            }
        }
    }

    /// Hides the panel and gives key status back.
    public func dismiss() {
        summoner.dismiss(returnFocus: true)
    }

    /// Shows the panel, or hides it when it shows.
    public func toggle(eventTimestamp: TimeInterval? = nil) {
        if summoner.isShown { dismiss() } else { summon(eventTimestamp: eventTimestamp) }
    }

    // MARK: Links

    /// Marks the session showing now as one a link opened or reached. Runs that start in it copy
    /// instead of pasting until the panel opens again some other way.
    public func noteLinkSession() {
        linkSession = sessionID
    }

    public func isLinkSession(_ session: Int) -> Bool {
        linkSession == session
    }

    /// Opens root search for a link, with the link's text typed. No row is selected until the
    /// user types, moves the selection or clicks a row, so Return and Command-1 to 9 run nothing
    /// the link chose. The session counts as a link session.
    public func showRootForLink(query: String) {
        popAll()
        summon()
        noteLinkSession()
        surface.queryField.text = query
        probe.begin(.keystroke)
        rootPage.showLinkQuery(query)
        probe.markApplied()
    }

    /// Shows a page a link asked for, such as the page that asks before a link runs a command. The
    /// session counts as a link session.
    ///
    /// While the user works in the panel, the page goes over the page they have open, which keeps
    /// its query and selection: Back, Cancel and the run the page starts all return to it, because
    /// going back to root from a link's page stops at the page under it. A card or the action
    /// panel showing is closed, and a question waiting in it is answered no. A second link's page
    /// replaces the first. While the panel is hidden, it opens on the page over root search.
    public func pushForLink(_ page: any PageController) {
        if isPanelVisible {
            pendingAnswer?.answer(false)
            pendingAnswer = nil
            if surface.overlay != nil { surface.dismissOverlay() }
            noteLinkSession()
            if let linkPage, top === linkPage { replaceTop(with: page) } else { push(page) }
        } else {
            popAll()
            summon()
            noteLinkSession()
            push(page)
        }
        linkPage = page
    }

    // MARK: Large Type

    /// Closes the panel, then shows the text in very large letters across the screen with the
    /// pointer, as Show in Large Type and Command-L do. Spaces and line breaks around the text are
    /// left out; nothing shows for text that is only those.
    public func showLargeType(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // The panel gives the keyboard to Large Type, not back to the app in front, so the next
        // key reaches Large Type. Large Type gives it back when it hides.
        if isPanelVisible { summoner.dismiss(returnFocus: false) }
        lastLargeType = text
        largeType.show(text)
    }

    /// Runs the action of the toast showing, as its button in the action bar does.
    public func runToastAction() {
        guard let visible = toasts.visible, let action = visible.toast.action, let origin = visible.origin else {
            return
        }
        runtime.pipeline.perform(action, origin: origin)
    }

    /// Prepares the next summon. Runs after every dismiss, whatever caused it.
    private func didDismiss() {
        pendingAnswer?.answer(false)
        pendingAnswer = nil
        if surface.overlay != nil { surface.dismissOverlay() }
        toasts.clear()
        rootPage.endSession()
        showTask?.cancel()
        showTask = nil
        top.panelDidHide()
        for page in stack.reversed() where page !== rootPage { page.panelDidClose() }
        if summoner.strategy != Self.strategy(general) { replaceSummoner() }
        guard let delay = HostSettings.resetToRootDelay(general[HostSettings.resetToRootAfter]) else { return }
        if delay == .zero {
            resetToRoot()
            return
        }
        let clock = runtime.services.clock
        resetTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !summoner.isShown else { return }
            resetToRoot()
        }
    }

    /// Pops every page and clears root search, while the panel is hidden.
    public func resetToRoot() {
        while stack.count > 1 { stack.removeLast().pageWillClose() }
        showTop(animated: false)
        rootPage.pageDidAppear(in: self)
        rootPage.resetForNextSummon()
        surface.queryField.text = ""
        updateChrome()
    }

    // MARK: Navigation

    /// The page for a Kit page a command returned. Asks ``pageFactory`` first, so grids, details
    /// and forms can plug in; lists are built in.
    public func makePage(_ page: Page, origin: RunOrigin) -> any PageController {
        if let made = pageFactory?(page, origin) { return made }
        switch page {
        case .list(let list): return ListPageController(page: list, origin: origin, preferences: runtime.preferences)
        case .grid(let grid): return GridPageController(page: grid, origin: origin, preferences: runtime.preferences)
        case .detail(let detail): return DetailPageController(page: detail, origin: origin)
        case .form(let form): return FormPageController(page: form, origin: origin)
        }
    }

    /// Makes a page before the built-in ones are tried, such as a feature-specific page in a test.
    /// Return nil to use the built-in page.
    public var pageFactory: ((Page, RunOrigin) -> (any PageController)?)?

    /// Pushes a page over the current one.
    public func push(_ page: any PageController) {
        let previous = top
        previous.pageDidDisappear()
        if previous === rootPage { rootPage.endSession() }
        configure(page)
        stack.append(page)
        showTop(animated: true)
        page.pageDidAppear(in: self)
        if !summoner.isShown { page.panelDidHide() }
        updateChrome()
    }

    /// Replaces the top page, so Back skips it. At root it pushes.
    public func replaceTop(with page: any PageController) {
        guard stack.count > 1 else { return push(page) }
        stack.removeLast().pageWillClose()
        configure(page)
        stack.append(page)
        showTop(animated: true)
        page.pageDidAppear(in: self)
        if !summoner.isShown { page.panelDidHide() }
        updateChrome()
    }

    /// Goes back one page.
    public func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast().pageWillClose()
        revealTop()
    }

    /// Goes back to root search. While a page a link pushed is on top, goes back to the page under
    /// it instead, so a link never costs the user the page they had open: see
    /// ``pushForLink(_:)``.
    public func popToRoot() {
        guard let linkPage, top === linkPage, let index = stack.firstIndex(where: { $0 === linkPage }), index > 1
        else { return popAll() }
        while stack.count > index { stack.removeLast().pageWillClose() }
        revealTop()
    }

    /// Pops every page down to root search.
    func popAll() {
        guard stack.count > 1 else { return }
        while stack.count > 1 { stack.removeLast().pageWillClose() }
        revealTop()
    }

    /// Shows the page below a popped one. While the panel is hidden the page hears that first, so
    /// it neither loads nor tells its source it shows again until the panel opens.
    private func revealTop() {
        showTop(animated: true)
        if !summoner.isShown { top.panelDidHide() }
        top.pageDidAppear(in: self)
        if top === rootPage, summoner.isShown { rootPage.beginSession() }
        updateChrome()
    }

    private func configure(_ page: any PageController) {
        page.contentView.sizing = sizing
        page.contentView.onHeightChange = { [weak self] in self?.surface.updateHeight(animated: false) }
    }

    /// Puts the top page's view, text, placeholder, breadcrumb and dropdown in the panel.
    private func showTop(animated: Bool) {
        let page = top
        let field = surface.queryField
        if field.arguments.isEmpty == false { field.arguments = [] }
        chipsCommand = nil
        field.ghostText = ""
        field.text = page.query
        field.placeholder = page.searchPlaceholder
        field.leading = page === rootPage ? .root : QueryLeading(glyph: .back, breadcrumb: page.title)
        field.filter = page.filter
        surface.setContent(page.contentView, animated: animated)
        surface.isLoading = false
        // A form or a preview took the keyboard: give it back to the search field.
        if surface.overlay == nil, !(page is FormPageController), field.window != nil {
            let editor = field.textField.currentEditor()
            if editor == nil || surface.panel.firstResponder !== editor { field.installEditor() }
        }
    }

    // MARK: Theme and sizing

    /// How tall content is under the current settings and theme.
    var sizing: PageContentView.Sizing {
        guard general[HostSettings.panelSizing] == .fixed else { return .fitContent }
        return .fixed(fixedContentHeight)
    }

    /// The height of the full list: the visible rows, two section headers and the padding.
    public var fixedContentHeight: CGFloat {
        let list = surface.theme.list
        let height =
            list.verticalPadding * 2 + list.rowHeight * Double(list.maxVisibleRows) + list.sectionHeaderHeight * 2
        return CGFloat(min(surface.theme.panel.maxContentHeight, height))
    }

    /// Applies the theme store's current theme and the general settings to the surface.
    func applyTheme() {
        var theme = themes?.current ?? baseTheme
        theme.list.maxVisibleRows = max(1, general[HostSettings.visibleRows])
        surface.theme = theme
        hud.apply(theme)
        largeType.apply(theme)
        let scale = Double(surface.panel.backingScaleFactor)
        rowMapper.rowIconSize = IconSize(points: theme.list.iconSize, scale: scale)
        rowMapper.accessoryIconSize = IconSize(points: theme.list.accessoryIconSize, scale: scale)
        let appearanceChanged = rowMapper.isDark != surface.resolvedTheme.isDark
        rowMapper.isDark = surface.resolvedTheme.isDark
        rowMapper.resolvedTheme = surface.resolvedTheme
        if appearanceChanged { for page in stack { page.appearanceDidChange() } }
        let sizing = sizing
        for page in stack { page.contentView.sizing = sizing }
        surface.updateHeight(animated: false)
    }

    private func startWatching() {
        if let themes {
            themeObserver = themes.addObserver { [weak self] changes in
                if changes.contains(.current) { self?.applyTheme() }
            }
        }
        let iconChanges = rowMapper.icons.changes.stream()
        watchers.append(
            Task { [weak self] in
                for await _ in iconChanges { self?.top.iconsDidChange() }
            })
        let keys = [
            HostSettings.panelSizing.erased, HostSettings.visibleRows.erased, HostSettings.inlineCompletion.erased,
            HostSettings.themeName.erased, HostSettings.summonStrategy.erased,
        ]
        let settingChanges = general.changes(ofAny: keys)
        watchers.append(
            Task { [weak self] in
                for await name in settingChanges { self?.settingDidChange(name) }
            })
        let directoryChanges = runtime.changes.stream()
        watchers.append(
            Task { [weak self] in
                for await _ in directoryChanges { self?.closePagesOfDisabledFeatures() }
            })
    }

    /// Pops every page a feature that was switched off pushed, with the pages above it.
    func closePagesOfDisabledFeatures() {
        guard
            let index = stack.firstIndex(where: { page in
                guard let featureID = page.featureID, let entry = runtime.feature(featureID) else { return false }
                return !entry.isEnabled
            }), index > 0
        else { return }
        while stack.count > index { stack.removeLast().pageWillClose() }
        revealTop()
    }

    private func settingDidChange(_ name: String) {
        if name == HostSettings.themeName.name {
            themes?.select(general[HostSettings.themeName])
        } else if name == HostSettings.summonStrategy.name {
            // While the panel shows, the next dismiss switches.
            if !summoner.isShown, summoner.strategy != Self.strategy(general) { replaceSummoner() }
        } else if name == HostSettings.inlineCompletion.name {
            rootPage.showsCompletion = general[HostSettings.inlineCompletion]
            updateChrome()
        } else {
            applyTheme()
        }
    }

    // MARK: Summon strategy

    /// The strategy the setting asks for.
    private static func strategy(_ general: FeatureSettings) -> SummonStrategy {
        general[HostSettings.summonStrategy] == .orderFront ? .orderFront : .layerOpacity
    }

    /// Replaces the summoner with one for the strategy the setting asks for, while the panel is
    /// hidden. It keeps the latency probe, the placement, the key settings with the summon order and
    /// the dismiss hook.
    /// After the prewarm the hidden panel's window follows the new strategy: ordered out for
    /// `orderFront`, ordered in at zero opacity for `layerOpacity`.
    private func replaceSummoner() {
        let old = summoner
        guard !old.isShown else { return }
        let next = Summoner(surface: surface, strategy: Self.strategy(general), probe: old.probe)
        next.followsPointerScreen = old.followsPointerScreen
        next.takesKeyStatus = old.takesKeyStatus
        next.makesKeyBeforeShowing = old.makesKeyBeforeShowing
        next.prepareNext = old.prepareNext
        old.prepareNext = nil
        summoner = next
        guard hasPrewarmed else { return }
        let panel = surface.panel
        switch next.strategy {
        case .orderFront:
            if panel.isVisible { panel.orderOut(nil) }
        case .layerOpacity:
            // Only a panel whose content is already invisible is ordered in.
            guard !panel.isVisible, surface.rootView.layer?.opacity == 0 else { return }
            surface.rootView.setAccessibilityHidden(true)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Chrome

    /// Refreshes the action bar, the ghost completion and the argument chips for the top page.
    func updateChrome() {
        let page = top
        // Root search runs this on every keystroke: it names the primary entry without building
        // the selected row's entries. Other pages build their target.
        let primaryTitle: String?
        let hasTarget: Bool
        if page === rootPage {
            primaryTitle = rootPage.primaryTitle
            hasTarget = rootPage.selectedRow != nil
        } else {
            let target = page.target
            primaryTitle = page.returnRunsPrimary ? target?.primary?.title : nil
            hasTarget = target != nil
        }
        let content = ActionBarContent(
            viewTitle: page.selectionTitle ?? page.title ?? HostStrings.appName, primaryTitle: primaryTitle,
            actionsTitle: hasTarget ? HostStrings.actionsTitle : nil)
        let surface = surface
        workMeter.measure { surface.actionBar.apply(content) }
        if let arguments = page as? ArgumentsPageController {
            updateArgumentChips(for: arguments)
            return
        }
        guard page === rootPage else { return }
        updateArgumentChips()
        let ghost = chipsCommand == nil ? rootPage.ghostText : ""
        workMeter.measure { surface.queryField.ghostText = ghost }
    }

    /// Shows argument chips while the selected root row is a command with arguments.
    private func updateArgumentChips() {
        var command: CommandEntry?
        if let selected = rootPage.selectedRow, selected.row.id.namespace == ItemID.ReservedNamespace.command,
            selected.kind != .fallbacks, let entry = runtime.command(selected.row.id),
            !entry.command.arguments.isEmpty
        {
            command = entry
        }
        guard command?.id != chipsCommand else { return }
        chipsCommand = command?.id
        let arguments = (command?.command.arguments ?? []).map { Self.queryArgument($0) }
        let field = surface.queryField
        workMeter.measure { field.arguments = arguments }
    }

    /// Shows the chips of the command a page asks arguments for, with the values known so far, and
    /// puts the keyboard in the first required one left empty.
    private func updateArgumentChips(for page: ArgumentsPageController) {
        guard page.command.id != chipsCommand else { return }
        chipsCommand = page.command.id
        let field = surface.queryField
        field.arguments = page.command.command.arguments.map { Self.queryArgument($0, value: page.values[$0.name]) }
        field.focusArgument(page.firstMissing(in: field.argumentValues) ?? 0)
    }

    nonisolated static func queryArgument(_ argument: CommandArgument, value: String? = nil) -> QueryArgument {
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        switch argument.kind {
        case .text:
            return QueryArgument(
                kind: .text, placeholder: argument.placeholder, value: value ?? argument.defaultValue ?? "")
        case .password:
            return QueryArgument(kind: .secure, placeholder: argument.placeholder, value: value ?? "")
        case .dropdown(let options):
            let menu = options.map { MenuOption(id: $0.value, title: $0.title) }
            return QueryArgument(
                kind: .dropdown(menu), placeholder: argument.placeholder,
                value: value ?? argument.defaultValue ?? options.first?.value ?? "")
        }
    }

    // MARK: PageHost

    public func pageSelectionDidChange(_ page: any PageController) {
        guard page === top else { return }
        updateChrome()
    }

    public func page(_ page: any PageController, isLoading: Bool) {
        guard page === top, surface.isLoading != isLoading else { return }
        let surface = surface
        workMeter.measure { surface.isLoading = isLoading }
    }

    public func pageFilterDidChange(_ page: any PageController) {
        guard page === top else { return }
        surface.queryField.filter = page.filter
    }

    public var preferences: HostPreferences { runtime.preferences }

    public func replaceQueryText(_ text: String) {
        surface.queryField.text = text
    }

    public func popPage(_ page: any PageController) {
        guard page === top else { return }
        pop()
    }

    public func openActions(for page: any PageController) {
        guard page === top else { return }
        openActionPanel()
    }

    public func runPrimaryAction(for page: any PageController) {
        guard page === top, let target = page.target, let entry = target.primary else { return }
        run(entry, target: target)
    }

    public func pageDidFail(_ page: any PageController, error: any Error) {
        guard !(error is CancellationError) else { return }
        let described = error as? any LocalizedError
        runtime.pipeline.showFailure(
            title: described?.errorDescription ?? HostStrings.somethingWentWrong, message: described?.failureReason)
    }
}

/// An answer the panel owes a waiting run: a confirmation or a permission card. Answered once; a
/// dismissed panel or a replaced card answers false.
@MainActor final class PendingAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?
    weak var card: NSView?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func answer(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
