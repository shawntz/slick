import Kit
import KitHosting
import LauncherUI
import Observation

/// The first-run flow: welcome, the hotkey, optional features, permissions, a theme, done.
///
/// The hotkey step leads with the recorder. When Spotlight's shortcut uses the launcher's keys, as
/// Command-Space does on a new Mac, the step says that continuing turns that shortcut off, and
/// Continue does so: it is the person's yes. The step then stays, with a green line once the app
/// binds the hotkey, or with the advice when the try failed, and the next Continue moves on. When
/// another macOS shortcut uses the keys, the step says where to turn it off and waits. The optional
/// features step lists every feature that is off until the user turns it on. A feature whose
/// manifest suggests it starts with its switch on, and the switches take effect when the user
/// continues past the step. The permissions step shows only what the features that are on need, in
/// groups. It never asks the system for a permission the user did not press Allow for, and a
/// request that macOS leaves unanswered shows where to allow it by hand. In a build that updates
/// itself, the done step has the automatic check switch, which starts on. Finishing stores that
/// choice and sets ``HostSettings/onboardingDone``.
/// Closing the window before that is finishing later: onboarding opens again at the next launch,
/// and switches the user did not continue past are not applied.
@Observable final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case hotkey
        case features
        case permissions
        case theme
        case done

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .hotkey: "Hotkey"
            case .features: "Optional Features"
            case .permissions: "Permissions"
            case .theme: "Theme"
            case .done: "Done"
            }
        }
    }

    /// What the hotkey step says about the launcher hotkey's binding.
    enum HotkeyGuide: Equatable {
        /// Nothing to explain: the hotkey is bound, cleared or refused, and never waited here.
        case none
        /// A macOS shortcut uses the stored combination, so nothing is bound yet. The wait says
        /// whether the app can turn that shortcut off, and whether a try failed.
        case waiting(LauncherHotkeyWait)
        /// The combination waited, and the app has bound it since.
        case freed(KeyCombo)
    }

    /// A feature that is off until the user turns it on.
    struct OptionalFeature: Identifiable, Equatable {
        var id: String
        var name: String
        /// The manifest's one sentence.
        var summary: String
        var icon: Icon
        var isEnabled: Bool
    }

    /// One permission the enabled features may need, with every feature's reason.
    struct PermissionItem: Identifiable {
        var permission: Permission
        /// The row's title, which names an Automation permission's app.
        var title: String
        var reasons: [(feature: String, reason: String)]
        var status: PermissionStatus
        var isSkipped: Bool
        /// What the row says in place of Allow and Skip while the permission waits for its app.
        var waitingSentence: String?
        /// True while the app asks macOS for it.
        var isAsking = false
        /// What the row says, with a button to System Settings, after a request macOS left
        /// unanswered and the permission is still not allowed.
        var unansweredSentence: String?
        var id: String { permission.settingsKey }
    }

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let onFinish: @MainActor () -> Void
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()
    private(set) var step: Step = .welcome
    /// The launcher hotkey's recorder.
    let hotkey: HotkeyRecorderModel
    private var skipped: Set<String> = []
    /// Permissions the app asks macOS for now.
    private var asking: Set<String> = []
    /// Permissions whose last request ended with no answer from macOS.
    private var unanswered: Set<String> = []
    /// True while Continue turns off the macOS shortcut that uses the launcher's keys.
    private(set) var isTakingKeys = false
    /// The user's switch for each optional feature, until the step applies them.
    private var featureChoices: [String: Bool] = [:]
    /// The last wait the app reported, so the step can confirm when it ends.
    private var seenWait: LauncherHotkeyWait?

    init(context: SettingsContext, onFinish: @escaping @MainActor () -> Void) {
        self.context = context
        self.onFinish = onFinish
        hotkey = context.recorder(HotkeyTargets.launcher(general: context.general, preferences: context.preferences))
        tasks.follow(context.directory.changes, bumping: revision)
        let recorder = hotkey
        tasks.add(
            Task { [stream = context.general.changes(of: HostSettings.launcherHotkey)] in
                for await _ in stream { recorder.refresh() }
            })
        if let status = context.launcherHotkey {
            seenWait = status.wait
            let changes = status.statusChanges.stream()
            tasks.add(
                Task { [weak self] in
                    for await _ in changes { self?.hotkeyStatusChanged() }
                })
        }
    }

    // MARK: Steps

    var canGoBack: Bool { step != .welcome && step != .done }

    /// Goes to the next step that has something to show. Leaving the optional features step turns
    /// each feature on or off as its switch shows, so the permissions step lists what they need.
    ///
    /// On the hotkey step, while the app can turn off the macOS shortcut that uses the launcher's
    /// keys, Continue does that instead and stays: the step then shows whether it worked, and the
    /// next Continue moves on.
    func next() async {
        guard !isTakingKeys else { return }
        if step == .hotkey, case .waiting(let wait) = hotkeyGuide, wait.canTurnOff,
            let status = context.launcherHotkey
        {
            isTakingKeys = true
            revision.bump()
            let taken = await status.turnOffSystemShortcut()
            isTakingKeys = false
            revision.bump()
            // Continue continues. A failed try stays on the step, which then says what to do by hand.
            guard taken else { return }
        }
        if step == .features { await applyFeatureChoices() }
        guard let following = nearest(from: step.rawValue + 1, by: 1) else { return }
        step = following
        hotkey.leave()
    }

    func back() {
        guard let previous = nearest(from: step.rawValue - 1, by: -1) else { return }
        step = previous
        hotkey.leave()
    }

    /// True when the step has something to show: the optional features step lists a feature and
    /// the permissions step a permission.
    func hasContent(_ target: Step) -> Bool {
        !isEmpty(target)
    }

    /// Goes straight to a step, for a scenario that pictures it. Switches the user set on the way
    /// are not applied. Returns false, and stays, when the step has nothing to show.
    @discardableResult
    func show(_ target: Step) -> Bool {
        guard hasContent(target) else { return false }
        step = target
        hotkey.leave()
        return true
    }

    /// The first step from `raw` in the direction `by` that has something to show.
    private func nearest(from raw: Int, by offset: Int) -> Step? {
        var candidate = Step(rawValue: raw)
        while let step = candidate, isEmpty(step) {
            candidate = Step(rawValue: step.rawValue + offset)
        }
        return candidate
    }

    private func isEmpty(_ step: Step) -> Bool {
        switch step {
        case .features: optionalFeatures.isEmpty
        case .permissions: permissionItems.isEmpty
        case .welcome, .hotkey, .theme, .done: false
        }
    }

    /// Stores the update choice, marks onboarding done and closes the flow.
    func finish() {
        if offersUpdates { context.dependencies.updates.setChecksAutomatically(checksForUpdates) }
        context.general[HostSettings.onboardingDone] = true
        onFinish()
    }

    // MARK: Updates

    /// True when the done step offers the automatic check switch: only a build that updates itself.
    var offersUpdates: Bool { context.dependencies.updates.isAvailable }

    /// The done step's switch. It starts on, and nothing is checked until finishing stores it.
    var checksForUpdates = true

    // MARK: Hotkey

    /// What the hotkey step explains now.
    var hotkeyGuide: HotkeyGuide {
        revision.track()
        guard let status = context.launcherHotkey else { return .none }
        if let wait = status.wait { return .waiting(wait) }
        if let seenWait, let bound = status.bound, bound == seenWait.combo, hotkey.combo == bound {
            return .freed(bound)
        }
        return .none
    }

    /// Opens the Keyboard pane of System Settings on its Spotlight shortcuts. Only the step's button
    /// calls it.
    func openKeyboardSettings() {
        context.openKeyboardSettings()
    }

    private func hotkeyStatusChanged() {
        if let wait = context.launcherHotkey?.wait { seenWait = wait }
        revision.bump()
    }

    // MARK: Optional features

    /// Every registered feature that is off until the user turns it on, in registration order,
    /// each with its switch as the step shows it. A feature stays listed after the user turns it on
    /// here, so the switch can turn it off again.
    var optionalFeatures: [OptionalFeature] {
        revision.track()
        return optionalEntries.map { entry in
            OptionalFeature(
                id: entry.id, name: entry.manifest.name, summary: entry.manifest.summary, icon: entry.manifest.icon,
                isEnabled: choice(for: entry))
        }
    }

    private var optionalEntries: [FeatureEntry] {
        context.directory.features.filter { !$0.manifest.isEnabledByDefault }
    }

    /// The switch the step shows for a feature: the user's choice here, or on for a feature the
    /// manifest suggests, or whether it is on now.
    private func choice(for entry: FeatureEntry) -> Bool {
        featureChoices[entry.id]
            ?? (entry.manifest.isSuggestedInOnboarding || context.preferences.isEnabled(feature: entry.id))
    }

    /// Draws feature icons.
    var icons: IconResolver { context.icons }

    /// Sets an optional feature's switch. It takes effect when the user continues past the step.
    func setEnabled(_ enabled: Bool, feature featureID: String) {
        featureChoices[featureID] = enabled
        revision.bump()
    }

    /// Turns each optional feature on or off as its switch shows, through the user's preferences,
    /// as the features pane does. A feature whose switch matches its state is left alone.
    func applyFeatureChoices() async {
        for entry in optionalEntries {
            let wanted = choice(for: entry)
            if wanted != context.preferences.isEnabled(feature: entry.id) {
                await context.preferences.setEnabled(wanted, feature: entry.id)
            }
        }
        revision.bump()
    }

    // MARK: Permissions

    /// Every permission an enabled feature names, in their groups' order, see ``PermissionGroup``.
    var permissionItems: [PermissionItem] {
        revision.track()
        var order: [Permission] = []
        var reasons: [Permission: [(feature: String, reason: String)]] = [:]
        for feature in context.directory.enabledFeatures {
            for need in feature.manifest.permissions {
                if reasons[need.permission] == nil { order.append(need.permission) }
                reasons[need.permission, default: []].append((feature.manifest.name, need.reason))
            }
        }
        let items = order.map { permission in
            let status = context.permissions.status(of: permission)
            let key = permission.settingsKey
            return PermissionItem(
                permission: permission, title: context.title(for: permission), reasons: reasons[permission] ?? [],
                status: status,
                isSkipped: skipped.contains(key),
                waitingSentence: context.waitingSentence(for: permission, status: status),
                isAsking: asking.contains(key),
                unansweredSentence: unanswered.contains(key) && !status.isGranted
                    ? PermissionGrant.unansweredSentence(permission) : nil)
        }
        return PermissionGroup.sorted(items, by: \.permission)
    }

    /// The permissions in their groups, each under its heading. A group with none is left out.
    var permissionGroups: [(group: PermissionGroup, items: [PermissionItem])] {
        PermissionGroup.grouped(permissionItems, by: \.permission)
    }

    /// Runs the grant flow for one permission the user chose to allow. It always ends: when macOS
    /// gives no answer, the row says where to allow the permission by hand.
    func allow(_ permission: Permission) async {
        let key = permission.settingsKey
        guard !asking.contains(key) else { return }
        skipped.remove(key)
        unanswered.remove(key)
        asking.insert(key)
        revision.bump()
        let status = await context.permissions.grant(permission)
        asking.remove(key)
        if status == .notDetermined { unanswered.insert(key) }
        revision.bump()
    }

    /// Opens the permission's place in System Settings. Only the button beside a request macOS left
    /// unanswered calls it.
    func openSettings(for permission: Permission) async {
        context.grants.watch(permission)
        await context.permissions.openSettings(for: permission)
    }

    /// Follows the status of every listed permission while the step shows, so an answer macOS gives
    /// late, or a grant made in System Settings, shows at once. The view runs it in a task that
    /// ends when the step goes away.
    func watchPermissions() async {
        let permissions = permissionItems.map(\.permission)
        for permission in permissions { context.grants.watch(permission) }
        await withTaskGroup(of: Void.self) { group in
            for permission in permissions {
                let stream = context.services.permissions.changes(of: permission)
                group.addTask { [weak self] in
                    for await _ in stream { await self?.permissionChanged(permission) }
                }
            }
        }
    }

    private func permissionChanged(_ permission: Permission) async {
        revision.bump()
        await context.grants.check(permission)
    }

    /// Leaves a permission for later. Features ask again when they need it.
    func skip(_ permission: Permission) {
        skipped.insert(permission.settingsKey)
        revision.bump()
    }

    // MARK: Theme

    var themes: [NamedTheme] {
        revision.track()
        return context.dependencies.themes.themes
    }

    var selectedTheme: String {
        revision.track()
        return context.dependencies.themes.selectedName
    }

    func selectTheme(_ name: String) {
        guard context.dependencies.themes.select(name) else { return }
        context.general[HostSettings.themeName] = context.dependencies.themes.selectedName
        revision.bump()
    }
}
