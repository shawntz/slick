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
nonisolated public final class MacPermissionSystem: PermissionSystem {
    private let home: URL
    private let location = LocationStatusReader()

    /// - Parameter homeDirectory: The home folder whose Desktop, Documents and Downloads the folder
    ///   permissions stand for.
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        home = homeDirectory
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
            return AutomationPermission.status(of: bundleID, askingIfNeeded: false)
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
            // macOS 27.2 has no request: the system asks when the app reads.
            break
        case .automation(let bundleID):
            return await Self.askAutomation(of: bundleID)
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

    public func open(settingsURL: URL) async {
        await MainActor.run {
            _ = NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Runs the probes off the main thread: the first read of a protected folder waits for the
    /// user to answer the system prompt.
    @concurrent private static func probe(_ targets: [AccessProbe.Target]) async -> PermissionStatus? {
        AccessProbe.run(targets)
    }

    /// Asks for Automation off the main thread: the call waits for the user to answer.
    @concurrent private static func askAutomation(of bundleID: String) async -> PermissionStatus? {
        AutomationPermission.status(of: bundleID, askingIfNeeded: true)
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

/// Automation consent through the Apple Event Manager.
nonisolated enum AutomationPermission {
    /// The consent for sending any Apple Event to the app. With `askingIfNeeded` the call may show a
    /// prompt and waits for the answer. Nil when the app is not running or the call failed.
    static func status(of bundleID: String, askingIfNeeded: Bool) -> PermissionStatus? {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        let result = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askingIfNeeded)
        return status(for: result)
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
