import Foundation
import Kit
import KitTesting
import Testing

@testable import Platform

/// iCloud Drive as a protected folder, and how soon a grant taken away in System Settings shows.
/// The center runs over ``FakePermissionSystem``; nothing asks macOS.
@Suite(.timeLimit(.minutes(1))) struct PermissionFreshnessTests {
    let system = FakePermissionSystem()
    let settings = PlatformSettings(backend: MemorySettingsBackend())
    let clock = FakeClock()
    static let home = URL(filePath: "/synthetic/home", directoryHint: .isDirectory)

    func makeCenter() -> PermissionCenter {
        PermissionCenter(system: system, settings: settings, clock: clock, pollInterval: .seconds(1))
    }

    func remembered(_ permission: Permission) -> SettingStorage? {
        settings.storage(for: PermissionCenter.storageName("status", for: permission))
    }

    // MARK: iCloud Drive

    @Test func iCloudDriveCountsOnlyItsOwnGrantNotFullDiskAccess() async {
        #expect(Permission.protectedFolder(.iCloudDrive).displayName == "iCloud Drive")
        let center = makeCenter()
        system.setAnswer(.granted, for: .fullDiskAccess)
        _ = await center.request(.fullDiskAccess)
        #expect(center.status(of: .protectedFolder(.desktop)) == .granted)
        #expect(center.status(of: .protectedFolder(.iCloudDrive)) == .notDetermined)
        // Asking reads iCloud Drive itself, even while Full Disk Access is on.
        system.setRecheck(.granted, for: .fullDiskAccess)
        system.setAnswer(.granted, for: .protectedFolder(.iCloudDrive))
        #expect(await center.request(.protectedFolder(.iCloudDrive)) == .granted)
        #expect(system.requests.last == .protectedFolder(.iCloudDrive))
        #expect(makeCenter().status(of: .protectedFolder(.iCloudDrive)) == .granted)
    }

    @Test func iCloudDriveThatIsOffStaysUnknown() async {
        let center = makeCenter()
        // The folder is missing, so the probe has no answer and nothing is remembered.
        #expect(await center.request(.protectedFolder(.iCloudDrive)) == .notDetermined)
        #expect(remembered(.protectedFolder(.iCloudDrive)) == nil)
    }

    @Test func backgroundReadsStayOutOfICloudDriveUntilItsOwnGrant() async {
        let center = makeCenter()
        let readGuard = ReadGuard.permissions(center, home: Self.home)
        let onDesktop = Self.home.appending(path: "Desktop/report.pdf")
        let inICloud = Self.home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/report.pdf")
        #expect(!readGuard.mayRead(onDesktop) && !readGuard.mayRead(inICloud))
        system.setAnswer(.granted, for: .fullDiskAccess)
        _ = await center.request(.fullDiskAccess)
        #expect(readGuard.mayRead(onDesktop))
        #expect(!readGuard.mayRead(inICloud))
        system.setAnswer(.granted, for: .protectedFolder(.iCloudDrive))
        _ = await center.request(.protectedFolder(.iCloudDrive))
        #expect(readGuard.mayRead(inICloud))
    }

    // MARK: Folders and Full Disk Access

    /// Found in review: with Full Disk Access on, a folder's probe passed and the center remembered a
    /// grant for the folder. After Full Disk Access went away the folder still read granted, and a
    /// file index would read it in the background, where macOS shows the folder prompt.
    @Test func aFolderAskedForWhileFullDiskAccessIsOnFollowsFullDiskAccess() async throws {
        let center = makeCenter()
        system.setRecheck(.granted, for: .fullDiskAccess)
        system.setAnswer(.granted, for: .protectedFolder(.desktop))
        #expect(await center.request(.protectedFolder(.desktop)) == .granted)
        #expect(!system.requests.contains(.protectedFolder(.desktop)))
        #expect(remembered(.protectedFolder(.desktop)) == nil)
        #expect(center.status(of: .fullDiskAccess) == .granted)

        // Full Disk Access is taken away. The next return finds out, and the folder follows.
        var changes = center.changes(of: .protectedFolder(.desktop)).makeAsyncIterator()
        system.setRecheck(.denied, for: .fullDiskAccess)
        #expect(center.userMayHaveReturned())
        #expect(await changes.next() == .notDetermined)
        #expect(center.status(of: .fullDiskAccess) == .denied)
    }

    @Test func aFolderAskedForWithoutFullDiskAccessIsProbedAndRemembered() async {
        let center = makeCenter()
        system.setRecheck(.denied, for: .fullDiskAccess)
        system.setAnswer(.granted, for: .protectedFolder(.documents))
        #expect(await center.request(.protectedFolder(.documents)) == .granted)
        #expect(system.requests == [.protectedFolder(.documents)])
        #expect(remembered(.protectedFolder(.documents)) == .string("granted"))
        // The recheck the user did not ask for leaves Full Disk Access as it was.
        #expect(center.status(of: .fullDiskAccess) == .notDetermined)
        #expect(remembered(.fullDiskAccess) == nil)
    }

    // MARK: Full Disk Access taken away

    @Test func aRememberedGrantIsCheckedAtLaunchAndOnReturnAtMostEveryTenSeconds() async throws {
        system.setAnswer(.granted, for: .fullDiskAccess)
        _ = await makeCenter().request(.fullDiskAccess)
        let relaunched = makeCenter()
        system.setRecheck(.granted, for: .fullDiskAccess)
        #expect(relaunched.userMayHaveReturned())  // as the app does at launch
        try await waitUntil { system.recheckCount == 1 }
        clock.advance(by: .seconds(5))
        #expect(!relaunched.userMayHaveReturned())

        var changes = relaunched.changes(of: .fullDiskAccess).makeAsyncIterator()
        system.setRecheck(.denied, for: .fullDiskAccess)
        clock.advance(by: .seconds(PermissionCenter.followUpRecheckInterval))
        #expect(relaunched.userMayHaveReturned())
        #expect(await changes.next() == .denied)
        #expect(makeCenter().status(of: .fullDiskAccess) == .denied)
        #expect(makeCenter().status(of: .protectedFolder(.documents)) == .notDetermined)
    }

    @Test func aGrantMadeInSettingsReachesAFolderThatWaitsForIt() async throws {
        let center = makeCenter()
        var changes = center.changes(of: .protectedFolder(.downloads)).makeAsyncIterator()
        system.setRecheck(.denied, for: .fullDiskAccess)
        #expect(center.userMayHaveReturned())
        try await waitUntil { system.recheckCount == 1 }
        #expect(center.status(of: .fullDiskAccess) == .notDetermined)
        #expect(remembered(.fullDiskAccess) == nil)

        system.setRecheck(.granted, for: .fullDiskAccess)
        #expect(!center.userMayHaveReturned())
        clock.advance(by: .seconds(PermissionCenter.followUpRecheckInterval))
        #expect(center.userMayHaveReturned())
        #expect(await changes.next() == .granted)
    }

    @Test func withNothingGrantedOrAwaitedNothingIsRechecked() {
        let center = makeCenter()
        #expect(!center.userMayHaveReturned())
        // A stream for iCloud Drive does not wait on Full Disk Access.
        let stream = center.changes(of: .protectedFolder(.iCloudDrive))
        #expect(!center.userMayHaveReturned())
        withExtendedLifetime(stream) {}
        #expect(system.recheckCount == 0)
    }
}
