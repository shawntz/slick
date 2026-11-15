import Foundation
import Kit
import Synchronization

/// What the permission center asks macOS. ``MacPermissionSystem`` is the live one.
nonisolated public protocol PermissionSystem: Sendable {
    /// The status from a call that never prompts and never shows a notification, or nil when no
    /// such call exists for the permission right now: Full Disk Access, protected folders, and
    /// Automation of an app that is not running.
    func check(_ permission: Permission) -> PermissionStatus?

    /// Asks macOS for the permission. May show a prompt, so only ``PermissionCenter/request(_:)``
    /// calls it. Nil when the answer is still unknown afterwards.
    func request(_ permission: Permission) async -> PermissionStatus?

    /// Opens a System Settings pane.
    func open(settingsURL: URL) async

    /// True when ``check(_:)`` for the permission may wait on another process, such as the TCC
    /// daemon. The center never makes the main thread wait for such a check.
    func checkMayWait(_ permission: Permission) -> Bool
}

extension PermissionSystem {
    public func checkMayWait(_ permission: Permission) -> Bool { true }
}

/// The live permission service: the rules on top of a ``PermissionSystem``.
///
/// - ``status(of:)`` uses only the system's non-prompting checks, and never makes the main thread
///   wait on one: some wait on the TCC daemon for 5 to 27 ms, such as Input Monitoring, Screen
///   Recording and Contacts on macOS 27.2. The center keeps each answer. A read of an answer older
///   than ``cacheLifetime`` returns it anyway and refreshes it in the background, and open streams
///   hear of a change. The first read of such a permission on the main thread returns the answer
///   the last check found, kept across launches, or `.notDetermined`, and checks in the
///   background. ``refresh(_:)`` warms every answer off the main thread; the app calls it at
///   launch.
/// - Accessibility and Screen Recording checks cannot tell "never asked" from "turned off", so
///   after Slick asked once, a missing grant reads `.denied`.
/// - Full Disk Access and protected folders have no safe check: reading a protected file to find
///   out can raise a "Data Access Blocked" notification on macOS 27. Their status is what the last
///   request found, remembered across launches, and `.notDetermined` before that. Full Disk Access
///   granted counts as every protected folder granted. Automation of an app that is not running is
///   remembered the same way.
/// - ``changes(of:)`` checks every ``pollInterval``, off the main thread, only while a stream is
///   open. A request or a refresh that changes the status tells open streams at once.
///
/// What the center remembers lives in the settings service under ``namespace``.
nonisolated public final class PermissionCenter: PermissionService {
    /// The settings namespace of what the center remembers. It contains a ".", which no feature ID
    /// may, so it cannot clash with a feature's settings.
    public static let namespace = "app.permissions"

    /// The permissions whose checks the app warms at launch: every one with a check that does not
    /// depend on another app.
    public static let checkedAtLaunch: [Permission] = [
        .accessibility, .inputMonitoring, .screenRecording, .calendars, .reminders, .contacts, .location, .pasteboard,
    ]

    /// How often an open ``changes(of:)`` stream checks the status.
    public let pollInterval: Duration
    /// How long a check's answer is used before a read refreshes it in the background.
    public let cacheLifetime: Duration
    private let system: any PermissionSystem
    private let settings: any SettingsService
    private let clock: any ClockService
    private let announcements = Broadcast<Announcement>()
    private let cache = Mutex<[Permission: CachedCheck]>([:])
    private let refreshing = Mutex<Set<Permission>>([])

    private struct Announcement: Sendable {
        var permission: Permission
        var status: PermissionStatus
    }

    private struct CachedCheck: Sendable {
        var status: PermissionStatus?
        var checkedAt: Date
    }

    public init(
        system: any PermissionSystem, settings: any SettingsService, clock: any ClockService,
        pollInterval: Duration = .seconds(1), cacheLifetime: Duration = .seconds(2)
    ) {
        self.system = system
        self.settings = settings
        self.clock = clock
        self.pollInterval = pollInterval
        self.cacheLifetime = cacheLifetime
    }

    public func status(of permission: Permission) -> PermissionStatus {
        resolve(permission, checked: cachedCheck(permission))
    }

    /// Asks macOS, unless a non-prompting check already reports the permission granted. A
    /// remembered status is never trusted here: when a feature found Full Disk Access missing after
    /// all, asking again is how the memory gets corrected.
    public func request(_ permission: Permission) async -> PermissionStatus {
        if await checkNow(permission) == .granted { return announceStatus(of: permission) }
        markAsked(permission)
        if let answer = await system.request(permission), answer != .notDetermined {
            remember(answer, for: permission)
        }
        await checkNow(permission)
        return announceStatus(of: permission)
    }

    public func openSettings(for permission: Permission) async {
        await system.open(settingsURL: PermissionSettingsLinks.url(for: permission))
    }

    public func changes(of permission: Permission) -> AsyncStream<PermissionStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: PermissionStatus.self)
        let last = Mutex(status(of: permission))
        let deliver: @Sendable (PermissionStatus) -> Void = { status in
            let changed = last.withLock { last -> Bool in
                defer { last = status }
                return last != status
            }
            if changed { continuation.yield(status) }
        }
        let subscription = announcements.subscribe { announcement in
            if announcement.permission == permission { deliver(announcement.status) }
        }
        let poller = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: pollInterval)
                } catch {
                    return
                }
                deliver(resolve(permission, checked: freshCheck(permission)))
            }
        }
        continuation.onTermination = { [weak self] _ in
            poller.cancel()
            self?.announcements.unsubscribe(subscription)
        }
        return stream
    }

    /// Checks the permissions now, off the main thread, and tells open streams of any change. The
    /// app calls it at launch with ``checkedAtLaunch``, so no later read waits.
    @concurrent public func refresh(_ permissions: [Permission]) async {
        for permission in permissions {
            freshCheck(permission)
            announceStatus(of: permission)
        }
    }

    // MARK: Checks

    /// Applies the rules to a check's answer.
    private func resolve(_ permission: Permission, checked: PermissionStatus?) -> PermissionStatus {
        if let checked {
            if checked == .notDetermined, Self.checkCannotTellDenied(permission), wasAsked(permission) {
                return .denied
            }
            return checked
        }
        if case .protectedFolder = permission,
            resolve(.fullDiskAccess, checked: cachedCheck(.fullDiskAccess)) == .granted
        {
            return .granted
        }
        return remembered(permission) ?? .notDetermined
    }

    /// The kept answer, refreshed in the background when it is old. A permission never checked
    /// before is checked now, unless that may wait and this is the main thread: then the answer
    /// the last check found stands in, and the check runs in the background.
    private func cachedCheck(_ permission: Permission) -> PermissionStatus? {
        guard let cached = cache.withLock({ $0[permission] }) else {
            guard Thread.isMainThread, system.checkMayWait(permission) else { return freshCheck(permission) }
            refreshInBackground(permission)
            return lastChecked(permission)
        }
        if clock.now.timeIntervalSince(cached.checkedAt) >= cacheLifetime.timeInterval {
            refreshInBackground(permission)
        }
        return cached.status
    }

    /// Asks the system now and keeps the answer. May wait on macOS.
    @discardableResult private func freshCheck(_ permission: Permission) -> PermissionStatus? {
        let status = system.check(permission)
        let now = clock.now
        cache.withLock { $0[permission] = CachedCheck(status: status, checkedAt: now) }
        if system.checkMayWait(permission), status != lastChecked(permission) {
            settings.set(status.map { .string(Self.name(of: $0)) }, for: Self.storageName("checked", for: permission))
        }
        return status
    }

    /// ``freshCheck(_:)`` off the caller's thread.
    @concurrent @discardableResult private func checkNow(_ permission: Permission) async -> PermissionStatus? {
        freshCheck(permission)
    }

    private func refreshInBackground(_ permission: Permission) {
        guard refreshing.withLock({ $0.insert(permission).inserted }) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            freshCheck(permission)
            refreshing.withLock { _ = $0.remove(permission) }
            announceStatus(of: permission)
        }
    }

    /// Tells open streams the permission's status; each stream passes it on only when it changed.
    @discardableResult private func announceStatus(of permission: Permission) -> PermissionStatus {
        let status = status(of: permission)
        announcements.send(Announcement(permission: permission, status: status))
        return status
    }

    /// Permissions whose check reports only granted or not, so `.notDetermined` may mean the user
    /// turned it off.
    private static func checkCannotTellDenied(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility, .screenRecording: true
        default: false
        }
    }

    // MARK: Memory

    /// The settings name under which the center remembers something about a permission.
    static func storageName(_ kind: String, for permission: Permission) -> String {
        namespace + "." + kind + "." + key(for: permission)
    }

    /// A stable name for a permission.
    static func key(for permission: Permission) -> String {
        switch permission {
        case .accessibility: "accessibility"
        case .inputMonitoring: "inputMonitoring"
        case .screenRecording: "screenRecording"
        case .fullDiskAccess: "fullDiskAccess"
        case .calendars: "calendars"
        case .reminders: "reminders"
        case .contacts: "contacts"
        case .location: "location"
        case .pasteboard: "pasteboard"
        case .automation(let bundleID): "automation." + bundleID
        case .protectedFolder(let folder): "protectedFolder." + folder.rawValue
        }
    }

    private func wasAsked(_ permission: Permission) -> Bool {
        settings.storage(for: Self.storageName("asked", for: permission)) == .bool(true)
    }

    private func markAsked(_ permission: Permission) {
        settings.set(.bool(true), for: Self.storageName("asked", for: permission))
    }

    /// What the last check of a permission whose check may wait found, at this launch or before.
    private func lastChecked(_ permission: Permission) -> PermissionStatus? {
        guard case .string(let raw) = settings.storage(for: Self.storageName("checked", for: permission)) else {
            return nil
        }
        return Self.status(named: raw)
    }

    private func remembered(_ permission: Permission) -> PermissionStatus? {
        guard case .string(let raw) = settings.storage(for: Self.storageName("status", for: permission)) else {
            return nil
        }
        return Self.status(named: raw)
    }

    private func remember(_ status: PermissionStatus, for permission: Permission) {
        settings.set(.string(Self.name(of: status)), for: Self.storageName("status", for: permission))
    }

    private static func name(of status: PermissionStatus) -> String {
        switch status {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        }
    }

    private static func status(named name: String) -> PermissionStatus? {
        switch name {
        case "granted": .granted
        case "denied": .denied
        case "notDetermined": .notDetermined
        case "restricted": .restricted
        default: nil
        }
    }
}

/// A permission system that reports one status for everything and never asks, for run
/// environments other than `live`.
nonisolated public struct FixedPermissionSystem: PermissionSystem {
    public let status: PermissionStatus

    public init(_ status: PermissionStatus = .granted) {
        self.status = status
    }

    public func check(_ permission: Permission) -> PermissionStatus? { status }

    public func request(_ permission: Permission) async -> PermissionStatus? { status }

    public func open(settingsURL: URL) async {}

    public func checkMayWait(_ permission: Permission) -> Bool { false }
}
