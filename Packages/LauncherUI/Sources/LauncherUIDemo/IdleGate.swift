import Foundation
import LauncherUITesting

/// The demo's logging wrapper around `IdleGuard`, which lives in LauncherUITesting so the app can
/// use it too: waits until nobody has touched the keyboard or mouse for a while, so a capture
/// that takes key status never catches a person mid-keystroke.
enum IdleGate {
    /// Seconds since the last keyboard or mouse input, or nil when the value cannot be read.
    static func idleSeconds() -> Double? { IdleGuard.idleSeconds() }

    /// Returns true once the machine has been idle for `seconds`, or false when `deadline`
    /// passes first or the idle time cannot be read.
    static func wait(seconds: Double, interval: Double = 3, until deadline: Date) async -> Bool {
        do {
            try await IdleGuard.wait(seconds: seconds, interval: interval, until: deadline) { idle in
                say("idle gate: input \(format(idle, 1)) s ago; waiting for \(Int(seconds)) s of idle")
            }
            return true
        } catch {
            switch error {
            case .unreadable: say("idle gate: HIDIdleTime unreadable; not capturing")
            case .deadline: say("idle gate: no idle moment before the deadline")
            }
            return false
        }
    }
}
