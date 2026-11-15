import AppKit
import Foundation

/// Switches the system appearance through System Events. Used only when the app runs for a person.
///
/// macOS has no public call that sets the system's appearance; `NSApp.appearance` changes only this
/// app. System Events offers it as the `dark mode` property of `appearance preferences`, so this
/// sends two Apple Events, a get and a set. That needs Automation permission for System Events,
/// which the command asks for through the host's card.
nonisolated final class LiveAppearance: AppearanceService {
    static let systemEventsID = "com.apple.systemevents"
    static let systemEvents = URL(
        filePath: "/System/Library/CoreServices/System Events.app", directoryHint: .isDirectory)

    init() {}

    @concurrent func toggleDarkMode() async throws -> Bool {
        let justLaunched = try await Self.launchSystemEvents()
        let target = AppleEvents.target(bundleID: Self.systemEventsID)
        // A System Events that has just started may not take events for a moment.
        var attempts = 0
        while true {
            do {
                try AppleEvents.checkPermission(for: target, bundleID: Self.systemEventsID)
                break
            } catch SystemFailure.unavailable where justLaunched && attempts < 10 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        // "dark mode" (thme) of "appearance preferences" (aprp) of the application, from
        // SystemEvents.sdef.
        let darkMode = AppleEvents.property("thme", of: AppleEvents.property("aprp", of: .null()))
        guard let current = try AppleEvents.get(darkMode, from: target, bundleID: Self.systemEventsID) else {
            throw SystemFailure.unavailable
        }
        let dark = !current.booleanValue
        try AppleEvents.set(
            darkMode, to: NSAppleEventDescriptor(boolean: dark), in: target, bundleID: Self.systemEventsID)
        return dark
    }

    /// Opens System Events in the background when it is not running, and returns true when it did.
    /// It is a faceless app that quits by itself after a while.
    private static func launchSystemEvents() async throws -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsID).isEmpty else {
            return false
        }
        guard FileManager.default.fileExists(atPath: systemEvents.path) else { throw SystemFailure.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: systemEvents, configuration: configuration)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        return true
    }
}
