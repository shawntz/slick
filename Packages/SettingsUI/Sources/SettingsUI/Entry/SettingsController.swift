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
    private var captureWindow: NSWindow?
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

    /// Closes the window, and the one ``showForCapture(_:at:)`` opened. Each keeps its state for
    /// the next time it shows.
    public func close() {
        window?.close()
        captureWindow?.close()
    }

    /// True while the window is on screen.
    public var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window on a pane with its bottom-left corner at `origin`, for a scenario that
    /// captures it. The app does not come forward, the window does not take key status, and its
    /// frame is not saved, so the place the user left the window stays as it was. The window keeps
    /// the place it is given, even off every screen, and stays fully transparent unless it is
    /// exactly there, so it never shows anywhere else. ``close()`` puts it away. Returns the
    /// frame to capture, or nil when the window could not be put at `origin`.
    @discardableResult
    public func showForCapture(_ pane: SettingsPaneID, at origin: CGPoint) -> CGRect? {
        model.show(pane)
        let window = captureWindow ?? makeWindow(savesFrame: false)
        captureWindow = window
        window.alphaValue = 0
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        guard window.frame.origin == origin else {
            window.orderOut(nil)
            return nil
        }
        window.alphaValue = 1
        return window.frame
    }

    /// The frame of the window ``showForCapture(_:at:)`` opened, while it is on screen.
    public var captureFrame: CGRect? {
        guard let captureWindow, captureWindow.isVisible else { return nil }
        return captureWindow.frame
    }

    private func present() {
        let window = self.window ?? makeWindow(savesFrame: true)
        self.window = window
        launcherHotkey?.checkNow()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app may not be allowed to activate; the window comes forward anyway.
        window.orderFrontRegardless()
    }

    private func makeWindow(savesFrame: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window =
            savesFrame ? SettingsWindow(contentViewController: hosting) : PlacedWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "\(Brand.name) Settings"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 640))
        guard savesFrame else { return window }
        window.setFrameAutosaveName("SettingsWindow")
        if window.frame.origin == .zero { window.center() }
        keyObserver = LauncherHotkeyCheck.observe(window, status: launcherHotkey)
        return window
    }
}

/// The window that settings and onboarding show in. While a hotkey recorder records, a click
/// anywhere else in the window ends the recording.
class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            (firstResponder as? HotkeyRecorderField)?.windowWillHandleMouseDown(at: event.locationInWindow)
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// A window that stays where it is put. AppKit moves a titled window back onto a screen when it
/// orders in; a capture window must stay at the place a scenario gives it, which tests put off
/// every screen.
final class PlacedWindow: SettingsWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The first-run window. App shows it at launch while ``isNeeded(_:)`` is true.
public final class OnboardingController {
    private let context: SettingsContext
    private let model: OnboardingModel
    private var window: NSWindow?
    private var captureWindow: NSWindow?
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

    /// The step the window shows, or would show when it opens.
    public var shownStep: OnboardingStepID {
        OnboardingStepID.allCases.first { OnboardingModel.Step($0) == model.step } ?? .welcome
    }

    /// True when the step has something to show. The optional features step needs a feature that
    /// is off by default, and the permissions step a permission that a feature that is on needs.
    public func canShow(_ step: OnboardingStepID) -> Bool {
        model.hasContent(OnboardingModel.Step(step))
    }

    /// Shows the window on a step with its bottom-left corner at `origin`, for a scenario that
    /// pictures it, as ``SettingsController/showForCapture(_:at:)`` does for the settings window.
    /// The app does not come forward and the window does not take key status. The window keeps the
    /// place it is given, even off every screen, and stays fully transparent unless it is exactly
    /// there, so it never shows anywhere else. Going to the step applies no switch and marks
    /// nothing done. As ``show()`` does, it has the launcher hotkey check whether a macOS shortcut
    /// holds it, so the hotkey step pictures the wait at once. ``close()`` puts the window away.
    /// Returns the frame to capture, or nil when the step has nothing to show or the window could
    /// not be put at `origin`.
    @discardableResult
    public func showForCapture(_ step: OnboardingStepID, at origin: CGPoint) -> CGRect? {
        guard model.show(OnboardingModel.Step(step)) else { return nil }
        context.launcherHotkey?.checkNow()
        let window = captureWindow ?? makeWindow(placed: true)
        captureWindow = window
        window.alphaValue = 0
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        guard window.frame.origin == origin else {
            window.orderOut(nil)
            return nil
        }
        window.alphaValue = 1
        return window.frame
    }

    /// Presses Continue on the step the window shows, as the person does, for a scenario. On the
    /// hotkey step, while the app can turn off the macOS shortcut that uses the launcher's keys,
    /// that is what Continue does.
    public func pressContinue() async {
        await model.next()
    }

    /// The frame of the window ``showForCapture(_:at:)`` opened, while it is on screen.
    public var captureFrame: CGRect? {
        guard let captureWindow, captureWindow.isVisible else { return nil }
        return captureWindow.frame
    }

    /// Closes the window, and the one ``showForCapture(_:at:)`` opened, without finishing
    /// onboarding.
    public func close() {
        window?.close()
        captureWindow?.close()
    }

    /// The window. A placed one is for captures: it stays where it is put and never watches for
    /// key status, which it never takes.
    private func makeWindow(placed: Bool = false) -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(model: model, toasts: context.toasts))
        let window =
            placed ? PlacedWindow(contentViewController: hosting) : SettingsWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(Brand.name)"
        window.isReleasedWhenClosed = false
        guard !placed else {
            // The window would take the view's size only after a layout pass, once it shows; a
            // capture needs its frame before that.
            window.setContentSize(hosting.view.fittingSize)
            return window
        }
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
