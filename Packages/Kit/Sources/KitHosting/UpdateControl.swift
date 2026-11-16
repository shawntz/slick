import Foundation
import Kit

/// Whether this build updates itself, and the person's choices about it.
///
/// The Updates package implements it with Sparkle, and only for the live launcher started from a
/// bundle whose Info.plist carries a feed address and a public key. Every other run, every test and
/// every build from source uses ``NoUpdates``. SettingsUI shows it in the General pane and in
/// onboarding, and App's menu bar item offers a check.
@MainActor public protocol UpdateControl: AnyObject, Sendable {
    /// True when this build can update itself. A build from source cannot, and updates with git.
    var isAvailable: Bool { get }

    /// True when the app checks for a new version on its own. It starts off, so nothing is checked
    /// until the person agrees.
    var checksAutomatically: Bool { get }

    /// Turns automatic checks on or off. Call it only for the person's choice: onboarding's switch
    /// or the General pane's.
    func setChecksAutomatically(_ enabled: Bool)

    /// When the app last asked for the feed, or nil when it never did.
    var lastCheck: Date? { get }

    /// The version a scheduled check found, which waits until the person looks at it, or nil.
    var waitingVersion: String? { get }

    /// True when a check can start now. False while an update downloads in the background.
    var canCheckNow: Bool { get }

    /// Checks for a new version now and shows the result in the updater's own window. Only a
    /// person's action calls it: a menu item or a button.
    func checkNow()

    /// Sent whenever one of the values above may have changed.
    var changes: ChangeSignal { get }
}

/// The updater of a build that cannot update itself. Every value is off and nothing happens.
@MainActor public final class NoUpdates: UpdateControl {
    public let changes = ChangeSignal()

    public init() {}

    public var isAvailable: Bool { false }
    public var checksAutomatically: Bool { false }
    public func setChecksAutomatically(_ enabled: Bool) {}
    public var lastCheck: Date? { nil }
    public var waitingVersion: String? { nil }
    public var canCheckNow: Bool { false }
    public func checkNow() {}
}
