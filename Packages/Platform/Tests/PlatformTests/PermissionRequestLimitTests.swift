import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Platform

/// A request always ends: a system that never answers, as when macOS shows no prompt for iCloud
/// Drive, holds a request for ``PermissionCenter/requestTimeLimit`` on the clock at most. The
/// answer the system gives later is still kept.
@Suite(.timeLimit(.minutes(1))) struct PermissionRequestLimitTests {
    let system = SilentPermissionSystem()
    let settings = PlatformSettings(backend: MemorySettingsBackend())
    let clock = FakeClock()

    func makeCenter() -> PermissionCenter {
        PermissionCenter(system: system, settings: settings, clock: clock, pollInterval: .seconds(1))
    }

    /// Runs a request in a task and moves the clock past the limit once the request waits on it.
    /// Returns the request's status, or nil, with an issue, when the request did not end: a request
    /// that waits for good fails the test here rather than hang it.
    func requestTimingOut(_ permission: Permission, center: PermissionCenter) async -> PermissionStatus? {
        let request = Task { await center.request(permission) }
        await system.waitForRequests(system.requests.count + 1)
        await clock.waitForSleepers()
        clock.advance(by: center.requestTimeLimit)
        let result = await Self.value(of: request)
        #expect(result != nil, "the request for \(permission) did not end at the limit")
        return result
    }

    /// The task's value once it ends, or nil when it has not ended within two seconds.
    static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
        let box = Mutex<T?>(nil)
        let waiter = Task {
            let value = await task.value
            box.withLock { $0 = value }
        }
        for _ in 0..<400 {
            if let value = box.withLock({ $0 }) { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        waiter.cancel()
        return nil
    }

    @Test func aFolderRequestNobodyAnswersEndsAtTheLimitAndReadsTheStatusAgain() async {
        let center = makeCenter()
        let iCloud = Permission.protectedFolder(.iCloudDrive)
        #expect(center.requestTimeLimit == .seconds(5))
        let status = await requestTimingOut(iCloud, center: center)
        #expect(status == .notDetermined)
        #expect(center.status(of: iCloud) == .notDetermined)
        #expect(system.requests == [iCloud])
        // Nothing was remembered for the folder.
        #expect(settings.storage(for: "app.permissions.status.protectedFolder.iCloudDrive") == nil)
        // The timer is gone once the request ended.
        #expect(clock.sleeperCount == 0)
        system.answer(nil, for: iCloud)
    }

    @Test func theSameGuardHoldsForEveryFolderAndFullDiskAccess() async {
        let center = makeCenter()
        var permissions = ProtectedFolder.allCases.map(Permission.protectedFolder)
        permissions.append(.fullDiskAccess)
        for permission in permissions {
            let status = await requestTimingOut(permission, center: center)
            #expect(status != nil && status != .granted, "\(permission)")
        }
        #expect(system.requests == permissions)
        for permission in permissions { system.answer(nil, for: permission) }
    }

    @Test func aLateAnswerIsKeptAndAnnounced() async throws {
        let center = makeCenter()
        let iCloud = Permission.protectedFolder(.iCloudDrive)
        let changes = center.changes(of: iCloud)
        var heard = changes.makeAsyncIterator()
        #expect(await requestTimingOut(iCloud, center: center) == .notDetermined)
        // The person answers a prompt that came up late.
        system.answer(.granted, for: iCloud)
        #expect(await heard.next() == .granted)
        #expect(center.status(of: iCloud) == .granted)
        #expect(settings.storage(for: "app.permissions.status.protectedFolder.iCloudDrive") == .string("granted"))
    }

    @Test func aSecondRequestJoinsTheOneThatRunsInsteadOfAskingAgain() async {
        let center = makeCenter()
        let iCloud = Permission.protectedFolder(.iCloudDrive)
        #expect(await requestTimingOut(iCloud, center: center) == .notDetermined)
        // Pressing Allow again does not start a second read that could wait as well.
        #expect(await requestTimingOut(iCloud, center: center) == .notDetermined)
        #expect(system.requests == [iCloud])
        system.answer(.denied, for: iCloud)
        await waitUntil { center.status(of: iCloud) == .denied }
        #expect(center.status(of: iCloud) == .denied)
    }

    @Test func anAnswerWithinTheLimitEndsTheRequestAtOnce() async {
        let center = makeCenter()
        let desktop = Permission.protectedFolder(.desktop)
        let request = Task { await center.request(desktop) }
        await system.waitForRequests(1)
        system.answer(.granted, for: desktop)
        #expect(await Self.value(of: request) == .granted)
        #expect(center.status(of: desktop) == .granted)
        // No time passed, and no timer is left.
        #expect(clock.sleeperCount == 0)
    }

    /// Waits for a condition the center reaches on another task. Two seconds at most.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A permission system whose requests wait until the test answers them, as when macOS shows no
/// prompt. Checks have no answer, as for folders.
nonisolated final class SilentPermissionSystem: PermissionSystem {
    private struct State {
        var requests: [Permission] = []
        var waiting: [Permission: [CheckedContinuation<PermissionStatus?, Never>]] = [:]
    }

    private let state = Mutex(State())

    var requests: [Permission] { state.withLock { $0.requests } }

    func check(_ permission: Permission) -> PermissionStatus? { nil }

    func checkMayWait(_ permission: Permission) -> Bool { false }

    func request(_ permission: Permission) async -> PermissionStatus? {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.requests.append(permission)
                state.waiting[permission, default: []].append(continuation)
            }
        }
    }

    func open(settingsURL: URL) async {}

    /// Answers every request for the permission that waits.
    func answer(_ status: PermissionStatus?, for permission: Permission) {
        let waiting = state.withLock { $0.waiting.removeValue(forKey: permission) ?? [] }
        for continuation in waiting { continuation.resume(returning: status) }
    }

    /// Waits until the system got `count` requests.
    func waitForRequests(_ count: Int) async {
        for _ in 0..<10_000 where requests.count < count {
            await Task.yield()
        }
    }
}
