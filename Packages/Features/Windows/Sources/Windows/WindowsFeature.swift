import Foundation
import Kit

/// Window management: move and resize the frontmost window from the launcher or a hotkey, and
/// switch between open windows.
///
/// - Twenty-eight layout commands come from the table in `WindowCommands.swift`, plus Toggle Full
///   Screen and Switch Windows. None has a hotkey. Two presets match popular window tools and are
///   only offered, never applied.
/// - The frame math in `Geometry/` is pure. The service reads the window, plans, moves and reads
///   back in one pass off the main thread: see `Arranger`.
/// - Runs are serial, the Kit default, so a second press of Left Half always sees where the first
///   one put the window and cycles on from there.
/// - Every side effect goes through ``WindowService``: Accessibility in the app, a simulated
///   desktop in scenarios, self-tests and tests.
public final class WindowsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "windows", name: Strings.featureName, icon: .symbol("macwindow"), summary: Strings.summary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.accessibilityReason)])

    let context: FeatureContext
    let windows: any WindowService
    /// Where the last layout command put a window, so a repeat can cycle.
    private(set) var lastPlacement: Placement?
    private(set) var restoreMemory = RestoreMemory()
    private(set) lazy var windowList = WindowList(windows: windows)

    /// Does no I/O. The live service touches nothing until a command runs.
    public init(context: FeatureContext) {
        self.context = context
        windows = context.service(WindowServiceKey.self)
    }

    public var commands: [Command] {
        WindowCommands.layouts.map(layoutCommand) + [fullScreenCommand, switchCommand]
    }

    public var hotkeyPresets: [HotkeyPreset] { WindowHotkeyPresets.all }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.hotkeysSection, items: [.note(Strings.noHotkeysNote), .note(Strings.turnOffNote)]),
            SettingsSection(
                Strings.layoutSection,
                items: [
                    .stepper(
                        Strings.windowGap, key: WindowsSettings.windowGap, range: WindowsSettings.gapRange, step: 2,
                        unit: Strings.pointsUnit, info: Strings.windowGapInfo),
                    .stepper(
                        Strings.screenGap, key: WindowsSettings.screenGap, range: WindowsSettings.gapRange, step: 2,
                        unit: Strings.pointsUnit, info: Strings.screenGapInfo),
                    .stepper(
                        Strings.almostMaximizeSize, key: WindowsSettings.almostMaximizePercent,
                        range: WindowsSettings.almostMaximizeRange, step: 5, unit: Strings.percentUnit,
                        info: Strings.almostMaximizeInfo),
                ]),
            SettingsSection(
                Strings.repeatSection,
                items: [
                    .picker(
                        Strings.repeatPicker, key: WindowsSettings.repeatBehavior, info: Strings.repeatInfo,
                        titles: Strings.repeatTitle)
                ]),
            SettingsSection(
                Strings.feedbackSection,
                items: [
                    .toggle(
                        Strings.showsLayoutName, key: WindowsSettings.showsLayoutName,
                        info: Strings.showsLayoutNameInfo)
                ]),
            SettingsSection(Strings.accessSection, items: [.permission(.accessibility, info: Strings.accessInfo)]),
        ])
    }

    // MARK: - Commands

    private func layoutCommand(_ spec: LayoutCommand) -> Command {
        Command(
            id: spec.id, title: spec.title, icon: .symbol(spec.symbol), keywords: spec.keywords,
            requires: [.accessibility]
        ) { _ in
            try await self.arrange(spec)
        }
    }

    private var fullScreenCommand: Command {
        Command(
            id: WindowCommands.toggleFullScreenID, title: Strings.toggleFullScreen,
            icon: .symbol("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"),
            keywords: Strings.windowKeywords, requires: [.accessibility]
        ) { _ in
            try await self.toggleFullScreen()
        }
    }

    private var switchCommand: Command {
        Command(
            id: WindowCommands.switchWindowsID, title: Strings.switchWindows, icon: .symbol("macwindow.on.rectangle"),
            keywords: Strings.switchKeywords, requires: [.accessibility]
        ) { _ in
            .push(
                .list(
                    ListPage(
                        self.windowList, searchPlaceholder: Strings.switchPlaceholder,
                        emptyState: EmptyState(
                            icon: .symbol("macwindow"), title: Strings.noWindowsTitle,
                            message: Strings.noWindowsMessage))))
        }
    }

    // MARK: - Running a layout

    /// Runs one layout command on the focused window and says what the HUD shows.
    func arrange(_ spec: LayoutCommand) async throws -> ActionOutcome {
        let options = WindowsSettings.options(context.settings)
        let request = LayoutRequest(
            command: spec.id, layout: spec.layout, options: options, lastPlacement: lastPlacement,
            restoreFrames: restoreMemory.frames)
        let outcome: LayoutOutcome
        do {
            outcome = try await windows.arrangeFocusedWindow(request)
        } catch WindowError.accessibilityMissing {
            // Turned off after the host checked. The host shows its card and runs the command again.
            return .needsPermission(.accessibility)
        }
        switch outcome {
        case .unchanged(let reason):
            return .close(hud: Self.hud(for: reason, layout: spec.layout))
        case .moved(let moved):
            if spec.layout == .restore {
                restoreMemory.forget(moved.window)
                lastPlacement = nil
            } else {
                restoreMemory.record(moved)
                lastPlacement = Placement(command: spec.id, window: moved.window, frame: moved.after, step: moved.step)
            }
            guard context.settings[WindowsSettings.showsLayoutName] else { return .close() }
            return .close(hud: HUD(Self.name(of: spec, step: moved.step, behavior: options.repeatBehavior)))
        }
    }

    private func toggleFullScreen() async throws -> ActionOutcome {
        let showsName = context.settings[WindowsSettings.showsLayoutName]
        do {
            switch try await windows.toggleFullScreen() {
            case .entered: return .close(hud: showsName ? HUD(Strings.enteredFullScreen) : nil)
            case .exited: return .close(hud: showsName ? HUD(Strings.exitedFullScreen) : nil)
            case .noWindow: return .close(hud: HUD(Strings.noWindow))
            case .unsupported: return .close(hud: .failure(Strings.fullScreenUnsupported))
            }
        } catch WindowError.accessibilityMissing {
            return .needsPermission(.accessibility)
        }
    }

    /// What the HUD calls a layout after it ran: the command's title, or the size a half cycled to.
    static func name(of spec: LayoutCommand, step: Int, behavior: RepeatBehavior) -> String {
        if case .half(let edge) = spec.layout, behavior == .cycleSizes {
            return Strings.halfStep(edge, step: step)
        }
        return spec.title
    }

    /// What the HUD says when a command left the window where it was.
    static func hud(for reason: Unchanged, layout: Layout) -> HUD {
        switch reason {
        case .noWindow: HUD(Strings.noWindow)
        case .fullScreen: HUD(Strings.fullScreen)
        case .cannotMove: .failure(Strings.cannotMove)
        case .noDisplay: .failure(Strings.noDisplay)
        case .onlyOneDisplay: HUD(Strings.onlyOneDisplay)
        case .nothingToRestore: HUD(Strings.nothingToRestore)
        case .atLimit: HUD(layout == .resize(grow: true) ? Strings.largest : Strings.smallest)
        }
    }
}
