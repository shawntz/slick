/// The update a scheduled check found, from when Sparkle reports it until the person looks at it.
///
/// A launcher works in the background, so while the menu bar item is shown, a scheduled check opens
/// no window and takes no focus. Sparkle's gentle reminders for background apps hand the scheduled
/// update to the app instead (https://sparkle-project.org/documentation/gentle-reminders/), and the
/// menu bar menu offers it until the person looks. The General pane names it in every case. Kept
/// apart from Sparkle, so tests need no Sparkle object.
nonisolated struct UpdateReminder: Equatable, Sendable {
    /// The display version of the update that waits, or nil while none does.
    private(set) var waitingVersion: String?

    /// Whether Sparkle shows an update a scheduled check found in its own window.
    ///
    /// Not while the menu bar item is shown: its menu leads with the update instead. When the person
    /// hid the item, no menu can remind them, and the update session would stay open unseen and stop
    /// every later scheduled check. So Sparkle then shows its window as it does for any background
    /// app: behind other apps' windows, or in front only just after launch.
    static func sparkleShowsScheduledUpdate(remindsInMenu: Bool) -> Bool {
        !remindsInMenu
    }

    /// Sparkle is about to show an update, or to leave showing it to the app. An update a scheduled
    /// check found waits. One the person asked for does not: they are looking at it.
    mutating func willShow(version: String, userInitiated: Bool) {
        waitingVersion = userInitiated ? nil : version
    }

    /// The person looked at the update, or the update session ends: installed, skipped, put off or
    /// failed.
    mutating func clear() {
        waitingVersion = nil
    }
}
