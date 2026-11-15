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

    /// Finds out again, without a prompt, the status of a permission that has no check, such as
    /// Full Disk Access after the user went to System Settings to grant it. Nil when it cannot.
    /// The center calls it only shortly after the user asked for the permission.
    func recheck(_ permission: Permission) async -> PermissionStatus?
}

extension PermissionSystem {
    public func checkMayWait(_ permission: Permission) -> Bool { true }

    public func recheck(_ permission: Permission) async -> PermissionStatus? { nil }
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
/// - Full Disk Access and protected folders have no check that never prompts: reading a protected
///   folder to find out can raise its prompt. Their status is what the last request or recheck
///   found, remembered across launches, and `.notDetermined` before that. Full Disk Access granted
///   counts as every protected folder granted.
/// - Automation can be checked only while the target app runs. The center remembers the last
///   answer a check found, so while the app is not running the status is that answer, or
///   `.notDetermined` when no check or request ever found one.
/// - Full Disk Access and Paste from Other Apps have no system prompt. A request that does not
///   find them granted opens their pane in System Settings. A second open of the same pane right
///   after, as the host does when a request fails, is skipped.
/// - ``changes(of:)`` streams share one poller, off the main thread, which runs only while a stream
///   is open. It checks every permission with an open stream every ``pollInterval`` while the app
///   is active or for ``fastPollingWindow`` after the user asked for a permission or opened its
///   pane, and every ``idlePollInterval`` otherwise. The app reports activity with
///   ``setAppActive(_:)``. A request or a refresh that changes the status tells open streams at
///   once.
/// - Full Disk Access has no check. Within ``fastPollingWindow`` after the user asked for it, the
///   center finds out again with ``PermissionSystem/recheck(_:)`` whenever the user may have come
///   back from System Settings: ``userMayHaveReturned()``, at most every two seconds, until it
///   finds the grant.
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

    /// How often open ``changes(of:)`` streams check while the app is active or the user just
    /// asked for a permission.
    public let pollInterval: Duration
    /// How often open streams check otherwise.
    public let idlePollInterval: Duration
    /// How long after the user asked for a permission, or opened its pane, checks run every
    /// ``pollInterval``.
    public let fastPollingWindow: Duration
    /// How long a check's answer is used before a read refreshes it in the background.
    public let cacheLifetime: Duration
    private let system: any PermissionSystem
    private let settings: any SettingsService
    private let clock: any ClockService
    private let announcements = Broadcast<Announcement>()
    private let cache = Mutex<[Permission: CachedCheck]>([:])
    private let refreshing = Mutex<Set<Permission>>([])
    private let polling = Mutex(Polling())

    /// The shared poller and what decides its pace.
    private struct Polling {
        /// Open streams per permission.
        var watched: [Permission: Int] = [:]
        var poller: Task<Void, Never>?
        var isAppActive = false
        /// When the user last asked for each permission or opened its pane.
        var askedAt: [Permission: Date] = [:]
        var lastOpened: (permission: Permission, date: Date)?
        var lastRecheck: Date?
    }

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
        pollInterval: Duration = .seconds(1), cacheLifetime: Duration = .seconds(2),
        idlePollInterval: Duration = .seconds(10), fastPollingWindow: Duration = .seconds(120)
    ) {
        self.system = system
        self.settings = settings
        self.clock = clock
        self.pollInterval = pollInterval
        self.cacheLifetime = cacheLifetime
        self.idlePollInterval = idlePollInterval
        self.fastPollingWindow = fastPollingWindow
    }

    public func status(of permission: Permission) -> PermissionStatus {
        resolve(permission, checked: cachedCheck(permission))
    }

    /// Asks macOS, unless a non-prompting check already reports the permission granted. A
    /// remembered status is never trusted here: when a feature found Full Disk Access missing after
    /// all, asking again is how the memory gets corrected.
    public func request(_ permission: Permission) async -> PermissionStatus {
        noteAsked(permission)
        if await checkNow(permission) == .granted { return announceStatus(of: permission) }
        markAsked(permission)
        if let answer = await system.request(permission), answer != .notDetermined {
            remember(answer, for: permission)
        }
        await checkNow(permission)
        let status = announceStatus(of: permission)
        if status != .granted, Self.onlySettingsCanGrant(permission) {
            await openSettings(for: permission)
        }
        return status
    }

    /// Opens the permission's pane, unless the same pane opened a moment ago.
    public func openSettings(for permission: Permission) async {
        let now = clock.now
        let isRepeat = polling.withLock { polling -> Bool in
            defer { polling.lastOpened = (permission, now) }
            guard let last = polling.lastOpened, last.permission == permission else { return false }
            return now.timeIntervalSince(last.date) < Self.repeatedOpenWindow
        }
        noteAsked(permission)
        guard !isRepeat else { return }
        await system.open(settingsURL: PermissionSettingsLinks.url(for: permission))
    }

    public func changes(of permission: Permission) -> AsyncStream<PermissionStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: PermissionStatus.self)
        let last = Mutex(status(of: permission))
        let subscription = announcements.subscribe { announcement in
            guard announcement.permission == permission else { return }
            let changed = last.withLock { last -> Bool in
                defer { last = announcement.status }
                return last != announcement.status
            }
            if changed { continuation.yield(announcement.status) }
        }
        startWatching(permission)
        continuation.onTermination = { [weak self] _ in
            self?.announcements.unsubscribe(subscription)
            self?.stopWatching(permission)
        }
        return stream
    }

    /// Tells the center whether the app is active, which makes open streams check every
    /// ``pollInterval``. Becoming active checks at once, and finds out again about Full Disk Access
    /// when the user asked for it shortly before.
    public func setAppActive(_ isActive: Bool) {
        let changed = polling.withLock { polling -> Bool in
            defer { polling.isAppActive = isActive }
            return polling.isAppActive != isActive
        }
        guard changed, isActive else { return }
        wakePoller()
        userMayHaveReturned()
    }

    /// Says the user may have come back from System Settings: the app became active, or another
    /// app came forward. Shortly after the user asked for Full Disk Access, which has no check, the
    /// center finds out again, at most every ``recheckInterval`` seconds, until it is granted.
    public func userMayHaveReturned() {
        let now = clock.now
        let shouldRecheck = polling.withLock { polling -> Bool in
            guard let asked = polling.askedAt[.fullDiskAccess], isRecent(asked) else { return false }
            if let last = polling.lastRecheck, now.timeIntervalSince(last) < Self.recheckInterval { return false }
            polling.lastRecheck = now
            return true
        }
        guard shouldRecheck else { return }
        Task.detached(priority: .utility) { [self] in
            if let answer = await system.recheck(.fullDiskAccess), answer != .notDetermined {
                remember(answer, for: .fullDiskAccess)
            }
            // Stop asking before anyone hears the answer. Announcing first let a listener come
            // back in while the ask was still on the books, which cost one more recheck.
            if status(of: .fullDiskAccess) == .granted {
                polling.withLock { _ = $0.askedAt.removeValue(forKey: .fullDiskAccess) }
            }
            announceStatus(of: .fullDiskAccess)
        }
    }

    /// True while open streams check every ``pollInterval``.
    public var isPollingFast: Bool {
        currentPollInterval() == pollInterval
    }

    /// Checks the permissions now, off the main thread, and tells open streams of any change. The
    /// app calls it at launch with ``checkedAtLaunch``, so no later read waits.
    @concurrent public func refresh(_ permissions: [Permission]) async {
        for permission in permissions {
            freshCheck(permission)
            announceStatus(of: permission)
        }
    }

    // MARK: Polling

    /// A second open of the same pane within this many seconds is skipped.
    static let repeatedOpenWindow: TimeInterval = 2
    /// The fewest seconds between two rechecks of Full Disk Access.
    static let recheckInterval: TimeInterval = 2

    /// Permissions macOS has no prompt for: the user grants them in System Settings.
    static func onlySettingsCanGrant(_ permission: Permission) -> Bool {
        switch permission {
        case .fullDiskAccess, .pasteboard: true
        default: false
        }
    }

    private func isRecent(_ date: Date) -> Bool {
        clock.now.timeIntervalSince(date) < fastPollingWindow.timeInterval
    }

    /// Records that the user asked for the permission now, which speeds up the poller.
    private func noteAsked(_ permission: Permission) {
        let now = clock.now
        polling.withLock { $0.askedAt[permission] = now }
        wakePoller()
    }

    private func currentPollInterval() -> Duration {
        let (isActive, askedAt) = polling.withLock { ($0.isAppActive, $0.askedAt) }
        if isActive || askedAt.values.contains(where: isRecent) { return pollInterval }
        return idlePollInterval
    }

    private func startWatching(_ permission: Permission) {
        let start = polling.withLock { polling -> Bool in
            polling.watched[permission, default: 0] += 1
            return polling.poller == nil
        }
        if start { restartPoller(checkingFirst: false) }
    }

    private func stopWatching(_ permission: Permission) {
        let poller = polling.withLock { polling -> Task<Void, Never>? in
            let count = (polling.watched[permission] ?? 0) - 1
            polling.watched[permission] = count > 0 ? count : nil
            guard polling.watched.isEmpty else { return nil }
            defer { polling.poller = nil }
            return polling.poller
        }
        poller?.cancel()
    }

    /// Restarts a running poller, so a new pace applies now and not after the current sleep.
    private func wakePoller() {
        restartPoller(checkingFirst: true)
    }

    /// Replaces the poller with a new one, unless no stream is open.
    private func restartPoller(checkingFirst: Bool) {
        let previous = polling.withLock { polling -> Task<Void, Never>? in
            guard !polling.watched.isEmpty else { return nil }
            defer { polling.poller = makePoller(checkingFirst: checkingFirst) }
            return polling.poller
        }
        previous?.cancel()
    }

    /// Checks every watched permission, then sleeps for the pace of the moment, until cancelled.
    private func makePoller(checkingFirst: Bool) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            var checksNow = checkingFirst
            while !Task.isCancelled {
                guard let self else { return }
                if !checksNow {
                    do {
                        try await self.clock.sleep(for: self.currentPollInterval())
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                }
                checksNow = false
                for permission in self.polling.withLock({ Array($0.watched.keys) }) {
                    self.freshCheck(permission)
                    self.announceStatus(of: permission)
                }
            }
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
        // The answer stands while the app is not running and the check has none.
        if case .automation = permission, let status, status != remembered(permission) {
            remember(status, for: permission)
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
