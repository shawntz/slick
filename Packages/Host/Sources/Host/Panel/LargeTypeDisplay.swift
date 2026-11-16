import AppKit
import Kit
import LauncherUI

/// Where Large Type goes: across the screen in the live launcher, into a list everywhere else. A
/// protocol so the scenario runner, the self-test, benchmarks and tests record the text instead of
/// putting a window on screen.
@MainActor public protocol LargeTypeDisplay: AnyObject {
    /// Shows the text in very large letters. The panel has closed already.
    func show(_ text: String)
    /// The theme the backing follows.
    func apply(_ theme: Theme)
}

/// Large Type in LauncherUI's ``LargeTypeWindow``, for the live launcher.
@MainActor public final class LargeTypeWindowDisplay: LargeTypeDisplay {
    public let window: LargeTypeWindow

    public init(theme: Theme = .standard) {
        window = LargeTypeWindow(theme: theme)
        // As the panel does when it closes: the app in front gets the keyboard back.
        window.onHide = { if NSApp.isActive { NSApp.deactivate() } }
    }

    public func show(_ text: String) {
        window.show(text)
    }

    public func apply(_ theme: Theme) {
        window.theme = theme
    }
}

/// Large Type recorded instead of shown, outside the live launcher.
@MainActor public final class RecordingLargeType: LargeTypeDisplay {
    /// Every text shown, oldest first.
    public private(set) var shown: [String] = []

    public init() {}

    public func show(_ text: String) {
        shown.append(text)
    }

    public func apply(_ theme: Theme) {}
}
