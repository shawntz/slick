import AppKit
import ApplicationServices
import Contacts
import CoreGraphics
import CoreLocation
import EventKit
import Foundation
import IOKit.hid
import Kit

/// The live permission system.
///
/// ``check(_:)`` uses only calls that never prompt: `AXIsProcessTrusted`,
/// `CGPreflightListenEventAccess` with `IOHIDCheckAccess`, `CGPreflightScreenCaptureAccess`, the
/// EventKit, Contacts and Core Location authorization status, `NSPasteboard.accessBehavior`, and
/// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false.
///
/// ``request(_:)`` calls the prompting APIs and runs the access probes. Only
/// ``PermissionCenter/request(_:)`` calls it, and tests never do.
///
/// Automation can be checked and asked only while the target app runs. A check never starts it,
/// so the check of an app that is not running has no answer, and the center reports the last one
/// it saw. A request never starts an app the user sees: for an app that is not running it asks
/// nothing, and ``waitsForApp(_:)`` says so. Only the faceless helpers in
/// ``AutomationPermission/helpersStartedToAsk`` are started hidden to ask: ``AutomationPermission``.
nonisolated public final class MacPermissionSystem: PermissionSystem {
    private let home: URL
    private let location = LocationStatusReader()
    private let automation: any AutomationSystem

    /// - Parameters:
    ///   - homeDirectory: The home folder whose Desktop, Documents and Downloads the folder
    ///     permissions stand for.
    ///   - automation: The Apple Event Manager and the apps it asks about.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        automation: any AutomationSystem = LiveAutomationSystem()
    ) {
        home = homeDirectory
        self.automation = automation
    }

    public func check(_ permission: Permission) -> PermissionStatus? {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            if CGPreflightListenEventAccess() { return .granted }
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied ? .denied : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendars:
            return Self.status(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.status(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            return Self.status(CNContactStore.authorizationStatus(for: .contacts))
        case .location:
            return location.status()
        case .pasteboard:
            return Self.status(NSPasteboard.general.accessBehavior)
        case .automation(let bundleID):
            return AutomationPermission.check(bundleID, using: automation)
        case .fullDiskAccess, .protectedFolder:
            return nil
        }
    }

    /// Input Monitoring, Screen Recording and Contacts wait on the TCC daemon for 5 to 27 ms on
    /// macOS 27.2, and Automation asks the Apple Event Manager. The other checks answer in under a
    /// few microseconds.
    public func checkMayWait(_ permission: Permission) -> Bool {
        switch permission {
        case .inputMonitoring, .screenRecording, .contacts, .automation: true
        default: false
        }
    }

    public func request(_ permission: Permission) async -> PermissionStatus? {
        switch permission {
        case .accessibility:
            await MainActor.run {
                // The documented value of kAXTrustedCheckOptionPrompt.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .location:
            return await LocationAuthorization.request()
        case .pasteboard:
            // macOS 27.2 has no request: the system asks when the app reads. The center opens
            // the pane instead.
            break
        case .automation(let bundleID):
            // The one call that may start an app to ask, and only a faceless helper, which shows
            // nothing and quits by itself.
            return await AutomationPermission.request(
                bundleID, using: automation,
                startingHelper: AutomationPermission.helpersStartedToAsk.contains(bundleID))
        case .fullDiskAccess:
            return await Self.probe(ProtectedLocations.fullDiskAccessTargets(home: home))
        case .protectedFolder(let folder):
            let home = home
            return await Self.probe(
                folder == .removableVolumes || folder == .networkVolumes
                    ? ProtectedLocations.targets(
                        for: folder, home: home,
                        removableVolumes: ProtectedLocations.mountedVolumes(network: false),
                        networkVolumes: ProtectedLocations.mountedVolumes(network: true))
                    : ProtectedLocations.targets(for: folder, home: home, removableVolumes: [], networkVolumes: []))
        }
        return check(permission)
    }

    /// True for Automation of an app that is not running and that a request would not start, so
    /// macOS can ask only the first time the user controls that app while it is open.
    public func waitsForApp(_ permission: Permission) -> Bool {
        guard case .automation(let bundleID) = permission else { return false }
        return !AutomationPermission.mayAsk(bundleID, using: automation)
    }

    /// Full Disk Access has no check, so after the user went to System Settings the probe runs
    /// again. It reads the Time Machine settings file and the Mail and Messages libraries, never
    /// another app's data, whose refusal posts a notification. Only the center's rule calls this:
    /// shortly after the user asked, when they may have come back, at most every two seconds.
    public func recheck(_ permission: Permission) async -> PermissionStatus? {
        guard permission == .fullDiskAccess else { return nil }
        return await Self.probe(ProtectedLocations.fullDiskAccessTargets(home: home))
    }

    public func open(settingsURL: URL) async {
        await MainActor.run {
            _ = NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Runs the probes on a thread of their own: the first read of a protected folder waits for the
    /// user to answer the system prompt, and for as long as macOS takes when it shows none.
    private static func probe(_ targets: [AccessProbe.Target]) async -> PermissionStatus? {
        await AccessProbe.runOnOwnThread(targets)
    }

    static func status(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // Write-only access cannot read events, which is what features ask for.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    static func status(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    static func status(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    static func status(_ behavior: NSPasteboard.AccessBehavior) -> PermissionStatus {
        switch behavior {
        // Default means the system never asked; on macOS 27.2 reads then succeed without a prompt.
        case .default, .alwaysAllow: .granted
        case .ask: .notDetermined
        case .alwaysDeny: .denied
        @unknown default: .notDetermined
        }
    }
}

/// What the Automation permission needs from macOS: whether an app runs, starting it hidden, and
/// the Apple Event Manager's answer. ``LiveAutomationSystem`` is the live one.
nonisolated public protocol AutomationSystem: Sendable {
    /// True when an app with the bundle ID runs in this session. Never prompts.
    func isRunning(_ bundleID: String) -> Bool
    /// Starts the app hidden, without bringing it forward. False when it is not installed or did
    /// not start.
    func launchHidden(_ bundleID: String) async -> Bool
    /// `AEDeterminePermissionToAutomateTarget` for any event to the app. With `askingIfNeeded` it
    /// may show the system prompt and wait for the answer, so never call it on the main thread.
    func determine(_ bundleID: String, askingIfNeeded: Bool) -> OSStatus
}

/// The live Automation calls.
nonisolated public struct LiveAutomationSystem: AutomationSystem {
    public init() {}

    public func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func launchHidden(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    public func determine(_ bundleID: String, askingIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askingIfNeeded)
    }
}

/// Automation consent through the Apple Event Manager, which answers only for a running app.
///
/// - A check never prompts and never starts the app. For an app that is not running it has no
///   answer.
/// - A request asks a running app, after the user pressed Grant. It starts nothing for an app that
///   is not running and returns nil, because starting a player such as Music or Spotify, even
///   hidden, is not what the user asked for. macOS then asks the first time the user controls that
///   app while it is open.
/// - The one exception is a faceless helper in ``helpersStartedToAsk``, which the caller names
///   explicitly: the request starts it hidden, waits until the Apple Event Manager finds it, then
///   asks.
nonisolated enum AutomationPermission {
    /// How long a request waits for an app it started to answer.
    static let launchWait: Duration = .seconds(5)

    /// Faceless helpers a request may start hidden to ask. Starting one shows nothing, and it quits
    /// by itself after a while. System Events is the System feature's way to switch Dark Mode, so
    /// onboarding and settings can still ask for it before the first use.
    static let helpersStartedToAsk: Set<String> = ["com.apple.systemevents"]

    /// True when a request for the app can ask now: it runs, or it is a helper a request starts.
    static func mayAsk(_ bundleID: String, using system: any AutomationSystem) -> Bool {
        helpersStartedToAsk.contains(bundleID) || system.isRunning(bundleID)
    }

    /// The status without asking. Nil when the app is not running.
    static func check(_ bundleID: String, using system: any AutomationSystem) -> PermissionStatus? {
        status(for: system.determine(bundleID, askingIfNeeded: false))
    }

    /// Asks the user and waits for the answer. An app that is not running is started hidden first
    /// only when `startingHelper` is true, which the caller passes for a faceless helper alone;
    /// otherwise nothing starts and nothing is asked. Nil when the app is not running and was not
    /// started, could not be started, or did not answer in time.
    @concurrent static func request(
        _ bundleID: String, using system: any AutomationSystem, startingHelper: Bool, wait: Duration = launchWait
    ) async -> PermissionStatus? {
        if !system.isRunning(bundleID) {
            guard startingHelper, await system.launchHidden(bundleID) else { return nil }
        }
        // An app that just started answers Apple Events a moment after it shows up as running.
        let deadline = ContinuousClock.now + wait
        while true {
            let result = system.determine(bundleID, askingIfNeeded: true)
            if Int(result) != procNotFound || ContinuousClock.now >= deadline { return status(for: result) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Granted, denied, not asked yet, or nil when the target is not running or the call failed.
    static func status(for result: OSStatus) -> PermissionStatus? {
        switch Int(result) {
        case Int(noErr): .granted
        case Int(errAEEventNotPermitted): .denied
        case Int(errAEEventWouldRequireUserConsent): .notDetermined
        default: nil
        }
    }
}

/// Reads Core Location's authorization status through one long-lived manager, which is cheaper
/// than making one per check. Making a manager never prompts. It is made on the main thread, as
/// Core Location expects, the first time a check needs it.
nonisolated final class LocationStatusReader: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var manager: CLLocationManager?

    func status() -> PermissionStatus {
        let manager = lock.withLock { manager } ?? makeManager()
        return MacPermissionSystem.status(manager.authorizationStatus)
    }

    private func makeManager() -> CLLocationManager {
        let made = MainThread.run { ManagerBox(CLLocationManager()) }.manager
        return lock.withLock {
            if let manager { return manager }
            manager = made
            return made
        }
    }

    /// Carries a manager made on the main thread back to the caller.
    private final class ManagerBox: @unchecked Sendable {
        let manager: CLLocationManager

        init(_ manager: CLLocationManager) {
            self.manager = manager
        }
    }
}

/// One request for location access, answered through the manager's delegate on the main thread.
@MainActor final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    /// Asks for location access while in use. Gives up after two minutes without an answer.
    static func request() async -> PermissionStatus? {
        let request = LocationAuthorization()
        let status = await request.run(timeout: .seconds(120))
        return MacPermissionSystem.status(status)
    }

    private func run(timeout: Duration) async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.answer(.notDetermined)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    private func answer(_ status: CLAuthorizationStatus) {
        continuation?.resume(returning: status)
        continuation = nil
        manager.delegate = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status != .notDetermined { answer(status) }
        }
    }
}
