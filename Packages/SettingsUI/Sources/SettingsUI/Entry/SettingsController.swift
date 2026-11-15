import AppKit
import Kit
import KitHosting
import SwiftUI

/// The settings window. App makes one at launch and calls ``show(_:)`` from Command-comma, the
/// menu bar item or a deep link.
///
/// The window is made on first show and kept, so the panes keep their state while the app runs.
/// Each time it opens or comes forward, the launcher hotkey checks whether a macOS shortcut still
/// holds it, so a user back from System Settings sees the result at once.
public final class SettingsController {
    private let model: SettingsModel
    private let launcherHotkey: (any LauncherHotkeyStatus)?
    private var window: NSWindow?
    private var keyObserver: (any NSObjectProtocol)?

    public init(dependencies: SettingsDependencies) {
        model = SettingsModel(dependencies: dependencies)
        launcherHotkey = dependencies.launcherHotkey
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// Opens the window on a pane and brings the app forward.
    public func show(_ pane: SettingsPaneID? = nil) {
        if let pane { model.show(pane) }
        present()
    }

    /// Opens the window on one feature's page, as a feature's Configure action does.
    public func showFeature(_ featureID: String) {
        model.showFeature(featureID)
        present()
    }

    /// Closes the window. It keeps its state for the next ``show(_:)``.
    public func close() {
        window?.close()
    }

    /// True while the window is on screen.
    public var isVisible: Bool { window?.isVisible ?? false }

    private func present() {
        let window = self.window ?? makeWindow()
        self.window = window
        launcherHotkey?.checkNow()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app may not be allowed to activate; the window comes forward anyway.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "\(Brand.name) Settings"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 640))
        window.setFrameAutosaveName("SettingsWindow")
        if window.frame.origin == .zero { window.center() }
        keyObserver = LauncherHotkeyCheck.observe(window, status: launcherHotkey)
        return window
    }
}

/// The first-run window. App shows it at launch while ``isNeeded(_:)`` is true.
public final class OnboardingController {
    private let context: SettingsContext
    private let model: OnboardingModel
    private var window: NSWindow?
    private var keyObserver: (any NSObjectProtocol)?

    /// - Parameter onFinish: Called after the user pressed Start and ``HostSettings/onboardingDone``
    ///   is set. The window has closed by then.
    public init(dependencies: SettingsDependencies, onFinish: @escaping @MainActor () -> Void = {}) {
        let context = SettingsContext(dependencies)
        let finish = FinishAction()
        self.context = context
        model = OnboardingModel(context: context, onFinish: { finish.run() })
        finish.run = { [weak self] in
            self?.window?.close()
            onFinish()
        }
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// True until the user finished onboarding once.
    public static func isNeeded(_ settings: any SettingsService) -> Bool {
        !HostSettings.settings(settings)[HostSettings.onboardingDone]
    }

    /// Shows the window and brings the app forward. An accessory app is not active, so it activates
    /// first, or the window would open behind the frontmost app.
    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        context.launcherHotkey?.checkNow()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS may refuse the activation, as when the user clicked elsewhere during the launch;
        // the window comes forward anyway.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(model: model, toasts: context.toasts))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(Brand.name)"
        window.isReleasedWhenClosed = false
        window.center()
        keyObserver = LauncherHotkeyCheck.observe(window, status: context.launcherHotkey)
        return window
    }
}

/// Checks the launcher hotkey again whenever a settings window becomes key, as when the user comes
/// back from System Settings.
private enum LauncherHotkeyCheck {
    static func observe(_ window: NSWindow, status: (any LauncherHotkeyStatus)?) -> (any NSObjectProtocol)? {
        guard let status else { return nil }
        return NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak status] _ in
            MainActor.assumeIsolated { status?.checkNow() }
        }
    }
}

/// Holds what finishing onboarding does, so the model can be made before the controller exists.
private final class FinishAction {
    var run: @MainActor () -> Void = {}
}
