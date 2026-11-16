import AppKit
import Contacts
import CoreLocation
import EventKit
import Foundation
import Kit
import KitTesting
import Testing

@testable import Platform

/// Every test but one runs the center over ``FakePermissionSystem``. The exception calls only the
/// live non-prompting checks.
@Suite(.timeLimit(.minutes(1))) struct PermissionTests {
    let system = FakePermissionSystem()
    let settings = PlatformSettings(backend: MemorySettingsBackend())
    let clock = FakeClock()

    func makeCenter() -> PermissionCenter {
        PermissionCenter(system: system, settings: settings, clock: clock, pollInterval: .seconds(1))
    }

    @Test func checkedStatusesPassThrough() {
        let center = makeCenter()
        system.setCheck(.granted, for: .calendars)
        system.setCheck(.restricted, for: .contacts)
        system.setCheck(.denied, for: .inputMonitoring)
        #expect(center.status(of: .calendars) == .granted)
        #expect(center.status(of: .contacts) == .restricted)
        #expect(center.status(of: .inputMonitoring) == .denied)
        #expect(system.requests.isEmpty)
    }

    @Test func accessibilityReadsDeniedOnlyAfterSlickAsked() async {
        let center = makeCenter()
        system.setCheck(.notDetermined, for: .accessibility)
        system.setCheck(.notDetermined, for: .calendars)
        #expect(center.status(of: .accessibility) == .notDetermined)
        #expect(await center.request(.accessibility) == .denied)
        #expect(system.requests == [.accessibility])
        // A check that can say "never asked" is trusted as it is.
        _ = await center.request(.calendars)
        #expect(center.status(of: .calendars) == .notDetermined)
    }

    @Test func fullDiskAccessIsUnknownUntilARequestAndThenRemembered() async {
        let center = makeCenter()
        #expect(center.status(of: .fullDiskAccess) == .notDetermined)
        #expect(center.status(of: .protectedFolder(.desktop)) == .notDetermined)
        #expect(system.requests.isEmpty)

        system.setAnswer(.granted, for: .fullDiskAccess)
        #expect(await center.request(.fullDiskAccess) == .granted)
        #expect(system.requests == [.fullDiskAccess])

        // A new center over the same settings, as after a relaunch, remembers it without asking.
        let relaunched = makeCenter()
        #expect(relaunched.status(of: .fullDiskAccess) == .granted)
        for folder in ProtectedFolder.allCases where folder != .iCloudDrive {
            #expect(relaunched.status(of: .protectedFolder(folder)) == .granted)
        }
        #expect(relaunched.status(of: .protectedFolder(.iCloudDrive)) == .notDetermined)

        // The user turned it off later. A feature finds out, the host asks again, and the probe
        // corrects the memory instead of the remembered grant short-circuiting the request.
        system.setAnswer(.denied, for: .fullDiskAccess)
        #expect(await relaunched.request(.fullDiskAccess) == .denied)
        #expect(system.requests == [.fullDiskAccess, .fullDiskAccess])
        #expect(makeCenter().status(of: .protectedFolder(.desktop)) == .notDetermined)
    }

    @Test func aProtectedFolderRemembersEachAnswer() async {
        let center = makeCenter()
        system.setAnswer(.denied, for: .protectedFolder(.documents))
        #expect(await center.request(.protectedFolder(.documents)) == .denied)
        #expect(center.status(of: .protectedFolder(.documents)) == .denied)
        #expect(center.status(of: .protectedFolder(.desktop)) == .notDetermined)
        // An answer that stays unknown, such as no removable volume to read, remembers nothing.
        #expect(await center.request(.protectedFolder(.removableVolumes)) == .notDetermined)
        #expect(settings.storage(for: "app.permissions.status.protectedFolder.removableVolumes") == nil)
    }

    @Test func automationOfAnAppThatIsNotRunningIsRemembered() async {
        let center = makeCenter()
        let mail = Permission.automation(bundleID: "com.example.mail")
        #expect(center.status(of: mail) == .notDetermined)
        system.setAnswer(.granted, for: mail)
        #expect(await center.request(mail) == .granted)
        #expect(center.status(of: mail) == .granted)
        system.setCheck(.denied, for: mail)
        await center.refresh([mail])
        #expect(center.status(of: mail) == .denied)
    }

    @Test func readsUseTheKeptAnswerAndRefreshItInTheBackground() async throws {
        let center = makeCenter()
        system.setCheck(.notDetermined, for: .contacts)
        #expect(center.status(of: .contacts) == .notDetermined)
        #expect(center.status(of: .contacts) == .notDetermined)
        #expect(system.checkCount == 1)  // the second read did not ask the system

        var changes = center.changes(of: .contacts).makeAsyncIterator()
        system.setCheck(.granted, for: .contacts)
        #expect(center.status(of: .contacts) == .notDetermined)  // still fresh: kept
        clock.set(clock.now.addingTimeInterval(3))  // older than the lifetime, without waking the poller
        #expect(center.status(of: .contacts) == .notDetermined)  // returned at once, refreshed after
        #expect(await changes.next() == .granted)
        #expect(center.status(of: .contacts) == .granted)
    }

    /// A main-thread read never waits for a check that waits on the TCC daemon. Found in review:
    /// the first read of Automation or Contacts used to block the caller.
    @Test func aFirstReadOnTheMainThreadNeverWaitsForASlowCheck() async throws {
        let center = makeCenter()
        // The check takes two seconds and a read may take one, so a busy machine cannot blur them.
        system.setSlow(.contacts, delay: .seconds(2))
        system.setCheck(.granted, for: .contacts)
        var changes = center.changes(of: .contacts).makeAsyncIterator()
        let started = ContinuousClock.now
        // Not determined is itself the proof: a read that waited would have said granted.
        #expect(center.status(of: .contacts) == .notDetermined)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await changes.next() == .granted)
        #expect(center.status(of: .contacts) == .granted)

        // At the next launch the last answer stands in until the background check returns.
        let relaunched = makeCenter()
        let again = ContinuousClock.now
        #expect(relaunched.status(of: .contacts) == .granted)
        #expect(ContinuousClock.now - again < .seconds(1))
        // A fast check is answered at once, even the first time.
        system.setCheck(.granted, for: .calendars)
        #expect(relaunched.status(of: .calendars) == .granted)
    }

    @Test func refreshChecksEveryPermissionOnce() async {
        let center = makeCenter()
        for permission in PermissionCenter.checkedAtLaunch {
            system.setCheck(.granted, for: permission)
        }
        await center.refresh(PermissionCenter.checkedAtLaunch)
        let checks = system.checkCount
        #expect(checks == PermissionCenter.checkedAtLaunch.count)
        for permission in PermissionCenter.checkedAtLaunch {
            #expect(center.status(of: permission) == .granted)
        }
        #expect(system.checkCount == checks)
        // Launch never makes a location manager: no feature asks for Location.
        #expect(!PermissionCenter.checkedAtLaunch.contains(.location))
    }

    @Test func aGrantedPermissionIsNeverRequestedAgain() async {
        let center = makeCenter()
        system.setCheck(.granted, for: .screenRecording)
        #expect(await center.request(.screenRecording) == .granted)
        #expect(system.requests.isEmpty)
    }

    @Test func changesPollOnlyWhileAStreamIsOpen() async throws {
        let center = makeCenter()
        center.setAppActive(true)  // checks every second
        system.setCheck(.notDetermined, for: .inputMonitoring)
        // The stream lives only inside the consumer, so it ends when the consumer is done with it.
        let consumer = Task {
            var statuses: [PermissionStatus] = []
            for await status in center.changes(of: .inputMonitoring) {
                statuses.append(status)
                if statuses.count == 2 { break }
            }
            return statuses
        }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))  // unchanged: nothing yielded
        await clock.waitForSleepers()
        system.setCheck(.granted, for: .inputMonitoring)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers()
        system.setCheck(.denied, for: .inputMonitoring)
        clock.advance(by: .seconds(1))
        #expect(await boundedValue(of: consumer) == [.granted, .denied])

        // The consumer is gone: the poller stops and nothing checks any more.
        try await waitUntil { clock.sleeperCount == 0 }
        let checks = system.checkCount
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(system.checkCount == checks)
    }

    @Test func cancellingTheConsumerStopsThePolling() async throws {
        let center = makeCenter()
        let stream = center.changes(of: .screenRecording)
        let consumer = Task {
            for await _ in stream {}
        }
        await clock.waitForSleepers()
        #expect(clock.sleeperCount == 1)
        consumer.cancel()
        await boundedValue(of: consumer)
        try await waitUntil { clock.sleeperCount == 0 }
    }

    /// Open streams share one poller: fast while the app is active or just after the user asked,
    /// slow otherwise, and none at all without a stream.
    @Test func pollingIsFastOnlyWhileActiveOrJustAfterAnAsk() async throws {
        let center = makeCenter()
        system.setCheck(.notDetermined, for: .inputMonitoring)
        system.setCheck(.notDetermined, for: .screenRecording)
        #expect(!center.isPollingFast)
        let first = center.changes(of: .inputMonitoring)
        let second = center.changes(of: .screenRecording)
        await clock.waitForSleepers()
        #expect(clock.sleeperCount == 1)  // one poller for both

        let checks = system.checkCount
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.checkCount == checks)  // slow: nothing after a second
        clock.advance(by: .seconds(9))
        try await waitUntil { system.checkCount == checks + 2 }

        // The user opens a pane: checks run at once, then every second.
        await center.openSettings(for: .inputMonitoring)
        #expect(center.isPollingFast)
        try await waitUntil { system.checkCount == checks + 4 }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        try await waitUntil { system.checkCount == checks + 6 }

        // Two minutes later it is slow again; becoming active makes it fast.
        await clock.waitForSleepers()
        clock.advance(by: .seconds(120))
        try await waitUntil { system.checkCount == checks + 8 }
        #expect(!center.isPollingFast)
        center.setAppActive(true)
        #expect(center.isPollingFast)
        try await waitUntil { system.checkCount == checks + 10 }
        center.setAppActive(false)
        #expect(!center.isPollingFast)

        withExtendedLifetime((first, second)) {}
    }

    @Test func withoutAStreamNothingPolls() async throws {
        let center = makeCenter()
        center.setAppActive(true)
        await center.openSettings(for: .accessibility)
        try await Task.sleep(for: .milliseconds(30))
        #expect(clock.sleeperCount == 0)
        let consumer = Task {
            for await _ in center.changes(of: .accessibility) {}
        }
        await clock.waitForSleepers()
        consumer.cancel()
        await boundedValue(of: consumer)
        try await waitUntil { clock.sleeperCount == 0 }
        center.setAppActive(false)
        center.setAppActive(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(clock.sleeperCount == 0)
    }

    /// Full Disk Access and Paste from Other Apps have no system prompt: a request that does not
    /// find them granted opens their pane, and the host's own open right after is skipped.
    @Test func aRequestOpensThePaneOfAPermissionOnlySettingsCanGrant() async {
        let center = makeCenter()
        system.setAnswer(.denied, for: .fullDiskAccess)
        #expect(await center.request(.fullDiskAccess) == .denied)
        await center.openSettings(for: .fullDiskAccess)
        #expect(system.openedURLs.map(\.query) == ["Privacy_AllFiles"])
        clock.advance(by: .seconds(3))
        await center.openSettings(for: .fullDiskAccess)
        #expect(system.openedURLs.count == 2)

        system.setCheck(.notDetermined, for: .pasteboard)
        #expect(await center.request(.pasteboard) == .notDetermined)
        #expect(system.openedURLs.last == PermissionSettingsLinks.url(for: .pasteboard))

        // A permission with a system prompt opens nothing by itself.
        system.setCheck(.notDetermined, for: .accessibility)
        _ = await center.request(.accessibility)
        #expect(system.openedURLs.count == 3)

        // Granted already: no pane.
        system.setAnswer(.granted, for: .fullDiskAccess)
        clock.advance(by: .seconds(3))
        #expect(await center.request(.fullDiskAccess) == .granted)
        #expect(system.openedURLs.count == 3)
    }

    /// Full Disk Access has no check. Found in review: after the user granted it in System
    /// Settings, the status stayed what the request's probe found, so the host's wait ran out.
    @Test func fullDiskAccessIsFoundOutAgainWhenTheUserMayHaveComeBack() async throws {
        let center = makeCenter()
        // Without an ask, coming back finds out nothing.
        center.userMayHaveReturned()
        center.setAppActive(true)
        center.setAppActive(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.recheckCount == 0)

        system.setAnswer(.denied, for: .fullDiskAccess)
        _ = await center.request(.fullDiskAccess)
        var changes = center.changes(of: .fullDiskAccess).makeAsyncIterator()
        system.setRecheck(.denied, for: .fullDiskAccess)
        center.userMayHaveReturned()  // System Settings came forward: not granted yet
        try await waitUntil { system.recheckCount == 1 }
        center.userMayHaveReturned()  // too soon after the last one
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.recheckCount == 1)

        system.setRecheck(.granted, for: .fullDiskAccess)
        clock.advance(by: .seconds(3))
        center.setAppActive(true)
        #expect(await changes.next() == .granted)
        #expect(center.status(of: .fullDiskAccess) == .granted)
        #expect(system.recheckCount == 2)

        // Found: no more rechecks.
        clock.advance(by: .seconds(3))
        center.userMayHaveReturned()
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.recheckCount == 2)
    }

    @Test func fullDiskAccessIsNotRecheckedOnceTheWindowHasPassed() async throws {
        let center = makeCenter()
        system.setAnswer(.denied, for: .fullDiskAccess)
        _ = await center.request(.fullDiskAccess)
        clock.advance(by: .seconds(121))
        center.userMayHaveReturned()
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.recheckCount == 0)
    }

    @Test func aRequestForAnAppThatIsNotRunningAsksNothingAndSaysSo() async {
        let center = makeCenter()
        let player = Permission.automation(bundleID: "com.example.player")
        system.setAnswer(.granted, for: player)
        system.setWaiting(player, true)
        #expect(center.waitsForApp(player))
        #expect(await center.request(player) == .notDetermined)
        #expect(system.requests.isEmpty, "the system was never asked, so nothing could start the app")
        #expect(system.openedURLs.isEmpty)

        system.setWaiting(player, false)
        #expect(!center.waitsForApp(player))
        #expect(await center.request(player) == .granted)
        #expect(system.requests == [player])
    }

    @Test func automationKeepsTheLastAnswerWhileTheAppIsNotRunning() async {
        let center = makeCenter()
        let events = Permission.automation(bundleID: "com.example.events")
        system.setCheck(.granted, for: events)
        await center.refresh([events])
        #expect(center.status(of: events) == .granted)
        system.setCheck(nil, for: events)  // the app quit
        await center.refresh([events])
        #expect(center.status(of: events) == .granted)
        #expect(makeCenter().status(of: events) == .granted)
        system.setCheck(.denied, for: events)
        await center.refresh([events])
        system.setCheck(nil, for: events)
        await center.refresh([events])
        #expect(center.status(of: events) == .denied)
    }

    @Test func aRequestTellsOpenStreamsAtOnce() async {
        let center = makeCenter()
        let stream = center.changes(of: .fullDiskAccess)
        var iterator = stream.makeAsyncIterator()
        system.setAnswer(.granted, for: .fullDiskAccess)
        _ = await center.request(.fullDiskAccess)
        #expect(await iterator.next() == .granted)
    }

    @Test func settingsOpenTheRightPane() async {
        let center = makeCenter()
        await center.openSettings(for: .accessibility)
        await center.openSettings(for: .protectedFolder(.downloads))
        #expect(
            system.openedURLs.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            ])
        let anchors: [Permission: String] = [
            .inputMonitoring: "Privacy_ListenEvent", .screenRecording: "Privacy_ScreenCapture",
            .fullDiskAccess: "Privacy_AllFiles", .calendars: "Privacy_Calendars", .reminders: "Privacy_Reminders",
            .contacts: "Privacy_Contacts", .location: "Privacy_LocationServices",
            .automation(bundleID: "com.example.mail"): "Privacy_Automation",
        ]
        for (permission, anchor) in anchors {
            #expect(PermissionSettingsLinks.url(for: permission).query == anchor)
        }
        #expect(PermissionSettingsLinks.url(for: .pasteboard).query == nil)
    }

    @Test func systemAnswersMapToKitStatuses() {
        #expect(MacPermissionSystem.status(EKAuthorizationStatus.fullAccess) == .granted)
        #expect(MacPermissionSystem.status(EKAuthorizationStatus.writeOnly) == .denied)
        #expect(MacPermissionSystem.status(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(MacPermissionSystem.status(EKAuthorizationStatus.restricted) == .restricted)
        #expect(MacPermissionSystem.status(CNAuthorizationStatus.authorized) == .granted)
        #expect(MacPermissionSystem.status(CNAuthorizationStatus.denied) == .denied)
        #expect(MacPermissionSystem.status(CLAuthorizationStatus.authorizedAlways) == .granted)
        #expect(MacPermissionSystem.status(CLAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(MacPermissionSystem.status(NSPasteboard.AccessBehavior.alwaysAllow) == .granted)
        #expect(MacPermissionSystem.status(NSPasteboard.AccessBehavior.default) == .granted)
        #expect(MacPermissionSystem.status(NSPasteboard.AccessBehavior.ask) == .notDetermined)
        #expect(MacPermissionSystem.status(NSPasteboard.AccessBehavior.alwaysDeny) == .denied)
        #expect(AutomationPermission.status(for: 0) == .granted)
        #expect(AutomationPermission.status(for: -1743) == .denied)
        #expect(AutomationPermission.status(for: -1744) == .notDetermined)
        #expect(AutomationPermission.status(for: -600) == nil)
    }

    /// Calls only the live checks that never prompt, and none that reads a protected location.
    @Test func liveChecksAnswerWithoutPrompting() {
        let live = MacPermissionSystem(homeDirectory: URL(filePath: "/synthetic/home"))
        for permission in [
            Permission.accessibility, .inputMonitoring, .screenRecording, .calendars, .reminders, .contacts,
        ] {
            #expect(live.check(permission) != nil, "\(permission)")
        }
        #expect(live.check(.fullDiskAccess) == nil)
        #expect(live.check(.protectedFolder(.desktop)) == nil)
    }

    @Test func probesReadOnlyWhereTheyAreTold() async throws {
        let folder = TemporaryFolder()
        let file = folder.url.appending(path: "sample.txt")
        try Data("x".utf8).write(to: file)
        #expect(AccessProbe.run([AccessProbe.Target(url: folder.url, isDirectory: true)]) == .granted)
        #expect(AccessProbe.run([AccessProbe.Target(url: file, isDirectory: false)]) == .granted)
        let missing = AccessProbe.Target(url: folder.url.appending(path: "missing"), isDirectory: true)
        #expect(AccessProbe.run([missing]) == nil)
        #expect(AccessProbe.run([missing, AccessProbe.Target(url: file, isDirectory: false)]) == .granted)
        #expect(AccessProbe.status(forErrno: EPERM) == .denied)
        #expect(AccessProbe.status(forErrno: ENOENT) == nil)
        // The live system runs its probes on a thread of their own, with the same answers.
        #expect(await AccessProbe.runOnOwnThread([AccessProbe.Target(url: folder.url, isDirectory: true)]) == .granted)
        #expect(await AccessProbe.runOnOwnThread([missing]) == nil)

        let home = URL(filePath: "/synthetic/home", directoryHint: .isDirectory)
        let desktop = ProtectedLocations.targets(for: .desktop, home: home, removableVolumes: [], networkVolumes: [])
        #expect(desktop.map { $0.url.path(percentEncoded: false) } == ["/synthetic/home/Desktop/"])
        let iCloud = ProtectedLocations.targets(for: .iCloudDrive, home: home, removableVolumes: [], networkVolumes: [])
        #expect(
            iCloud.map { $0.url.path(percentEncoded: false) } == [
                "/synthetic/home/Library/Mobile Documents/com~apple~CloudDocs/"
            ])
        #expect(iCloud.allSatisfy { $0.isDirectory })
        let volume = URL(filePath: "/Volumes/SYNTHETIC", directoryHint: .isDirectory)
        #expect(
            ProtectedLocations.targets(
                for: .removableVolumes, home: home, removableVolumes: [volume], networkVolumes: []
            )
            .map(\.url) == [volume])
        let fullDisk = ProtectedLocations.fullDiskAccessTargets(home: home)
        #expect(fullDisk.allSatisfy { !$0.url.path(percentEncoded: false).contains("Safari") })
        withExtendedLifetime(folder) {}
    }

    @Test func outsideLiveEverythingIsGrantedAndNothingAsks() async {
        let center = PermissionCenter(system: FixedPermissionSystem(), settings: settings, clock: clock)
        #expect(center.status(of: .fullDiskAccess) == .granted)
        #expect(center.status(of: .accessibility) == .granted)
        #expect(await center.request(.contacts) == .granted)
    }
}
