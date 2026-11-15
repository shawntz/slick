import Kit
import KitHosting
import LauncherUI
import Observation

/// The first-run flow: welcome, the hotkey, optional permissions, a theme, done.
///
/// It never asks the system for a permission the user did not press Allow for. Finishing sets
/// ``HostSettings/onboardingDone``.
@Observable final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case hotkey
        case permissions
        case theme
        case done

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .hotkey: "Hotkey"
            case .permissions: "Permissions"
            case .theme: "Theme"
            case .done: "Done"
            }
        }
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
    private let revision = Revision()
    private(set) var step: Step = .welcome
    /// The launcher hotkey's recorder.
    let hotkey: HotkeyRecorderModel
    private var skipped: Set<String> = []

    init(context: SettingsContext, onFinish: @escaping @MainActor () -> Void) {
        self.context = context
        self.onFinish = onFinish
        hotkey = context.recorder(HotkeyTargets.launcher(general: context.general, preferences: context.preferences))
    }

    // MARK: Steps

    var canGoBack: Bool { step != .welcome && step != .done }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        if following == .permissions && permissionItems.isEmpty {
            step = .theme
        } else {
            step = following
        }
        hotkey.endRecording()
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        if previous == .permissions && permissionItems.isEmpty {
            step = .hotkey
        } else {
            step = previous
        }
    }

    /// Marks onboarding done and closes the flow.
    func finish() {
        context.general[HostSettings.onboardingDone] = true
        onFinish()
    }

    // MARK: Hotkey

    /// The combination macOS gives Spotlight, which the launcher cannot take while Spotlight has it.
    static let spotlightCombo = KeyCombo(.space, .command)

    var spotlightNote: String {
        "Spotlight keeps \(Self.spotlightCombo.displayString) unless you turn off its shortcut in System Settings, under Keyboard Shortcuts. \(KeyCombo(.space, .option).displayString) is free on most Macs."
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
