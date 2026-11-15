import AppKit
import Foundation
import Kit

/// One launcher at a time. A second copy started while one runs asks the running one to open its
/// panel, then quits. Only the live launcher checks; selftests, benches and scenarios may run
/// beside it, each in its own temporary data folder.
enum SingleInstance {
    /// The distributed notification a second copy posts.
    static let summonNotification = Notification.Name(Brand.bundleID + ".summon")

    /// The process IDs of other running copies, given every running copy's process ID.
    nonisolated static func others(among running: [pid_t], me: pid_t) -> [pid_t] {
        running.filter { $0 != me }
    }

    /// True when another copy of the app runs.
    static func anotherCopyRuns() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleID)
        return !others(among: running.map(\.processIdentifier), me: getpid()).isEmpty
    }

    /// Asks the running copy to open its panel.
    static func askRunningCopyToSummon() {
        DistributedNotificationCenter.default().postNotificationName(
            summonNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `summon` on the main actor whenever a second copy asks. Returns the observer to remove.
    static func listen(_ summon: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: summonNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { summon() }
        }
    }
}
