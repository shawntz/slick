import Kit
import KitHosting
import LauncherUI
import Observation

/// The first-run flow: welcome, the hotkey, optional features, permissions, a theme, done.
///
/// The hotkey step leads with the recorder. When a macOS shortcut holds the launcher hotkey, as
/// Spotlight holds Command-Space on a new Mac, it shows how to turn that shortcut off and a line
/// that turns green the moment the app binds the hotkey. The optional features step lists every
/// feature that is off until the user turns it on, and the permissions step shows only what the
/// features that are on need. It never asks the system for a permission the user did not press
/// Allow for. Finishing sets ``HostSettings/onboardingDone``.
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
        /// A macOS shortcut holds the stored combination, so nothing is bound yet.
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
        var reasons: [(feature: String, reason: String)]
        var status: PermissionStatus
        var isSkipped: Bool
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

    func next() {
        guard let following = nearest(from: step.rawValue + 1, by: 1) else { return }
        step = following
        hotkey.endRecording()
    }

    func back() {
        guard let previous = nearest(from: step.rawValue - 1, by: -1) else { return }
        step = previous
        hotkey.endRecording()
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

    /// Marks onboarding done and closes the flow.
    func finish() {
        context.general[HostSettings.onboardingDone] = true
        onFinish()
    }

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

    /// Every registered feature that is off until the user turns it on, in registration order. A
    /// feature stays listed after the user turns it on here, so the switch can turn it off again.
    var optionalFeatures: [OptionalFeature] {
        revision.track()
        return context.directory.features.filter { !$0.manifest.isEnabledByDefault }.map { entry in
            OptionalFeature(
                id: entry.id, name: entry.manifest.name, summary: entry.manifest.summary, icon: entry.manifest.icon,
                isEnabled: context.preferences.isEnabled(feature: entry.id))
        }
    }

    /// Draws feature icons.
    var icons: IconResolver { context.icons }

    /// Turns an optional feature on or off through the user's preferences, as the features pane
    /// does. The permissions step then lists what it needs.
    func setEnabled(_ enabled: Bool, feature featureID: String) async {
        await context.preferences.setEnabled(enabled, feature: featureID)
        revision.bump()
    }

    // MARK: Permissions

    /// Every permission an enabled feature names, in the order features name them.
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
        return order.map { permission in
            PermissionItem(
                permission: permission, reasons: reasons[permission] ?? [],
                status: context.permissions.status(of: permission),
                isSkipped: skipped.contains(permission.settingsKey))
        }
    }

    /// Runs the grant flow for one permission the user chose to allow.
    func allow(_ permission: Permission) async {
        skipped.remove(permission.settingsKey)
        _ = await context.permissions.grant(permission)
        revision.bump()
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
