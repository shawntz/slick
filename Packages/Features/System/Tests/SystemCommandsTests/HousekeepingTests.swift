import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

@Suite("Empty Trash", .timeLimit(.minutes(1)))
@MainActor
struct EmptyTrashTests {
    @Test func asksWithTheCountThenDeletesWithThePanelClosed() async throws {
        let system = SystemHarness(trashItems: 9, volumeTrashItems: 3)
        let outcome = try await system.harness.run("empty-trash")
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Empty the Trash?")
        #expect(confirmation.message == "The 12 items in the Trash will be deleted forever. You can't undo this.")
        #expect(confirmation.confirmTitle == "Empty Trash")
        #expect(confirmation.isDestructive)
        #expect(confirmation.suppressionKey == nil)
        #expect(system.housekeeping.requests == [.emptyTrash(includingVolumes: true)])
        #expect(outcome.kind == .close(hud: .success("Deleted 12 items from the Trash")))
        #expect(system.housekeeping.trashItems == 0)
    }

    @Test func oneItemReadsAsOne() async throws {
        let system = SystemHarness(trashItems: 1)
        try await system.harness.run("empty-trash")
        #expect(
            system.harness.confirmations.first?.message
                == "The item in the Trash will be deleted forever. You can't undo this.")
        #expect(system.harness.huds == [.success("Deleted 1 item from the Trash")])
    }

    @Test func anEmptyTrashSaysSoWithoutAsking() async throws {
        let system = SystemHarness()
        let outcome = try await system.harness.run("empty-trash")
        #expect(outcome.kind == .close(hud: "The Trash is already empty"))
        #expect(system.harness.confirmations.isEmpty)
        #expect(system.housekeeping.requests.isEmpty)
    }

    @Test func decliningDeletesNothing() async throws {
        let system = SystemHarness(trashItems: 4)
        system.harness.confirmationAnswer = false
        let outcome = try await system.harness.run("empty-trash")
        #expect(outcome.kind == .keepOpen)
        #expect(system.housekeeping.requests.isEmpty)
        #expect(system.housekeeping.trashItems == 4)
    }

    @Test func otherDisksAreLeftOutWithoutFullDiskAccess() async throws {
        let system = SystemHarness(trashItems: 2, volumeTrashItems: 5)
        system.fakes.permissions.set(.fullDiskAccess, to: .denied)
        try await system.harness.run("empty-trash")
        #expect(
            system.harness.confirmations.first?.message
                == "The 2 items in the Trash will be deleted forever. You can't undo this.")
        #expect(system.housekeeping.requests == [.emptyTrash(includingVolumes: false)])
    }

    @Test func aGuardedTrashShowsThePermissionCard() async throws {
        let system = SystemHarness(trashItems: 2)
        system.housekeeping.failTrash(with: .permissionMissing(.fullDiskAccess))
        await #expect(throws: HarnessError.permissionRequired([.fullDiskAccess])) {
            try await system.harness.run("empty-trash")
        }
        #expect(system.harness.confirmations.isEmpty)
    }

    @Test func itemsThatStaySayHowManyAndWhy() async throws {
        let system = SystemHarness(trashItems: 5)
        system.housekeeping.keepInTrash(2)
        try await system.runShowingErrors("empty-trash")
        #expect(system.failureHUDs == ["2 items could not be deleted"])
        let failure = try #require(system.harness.actionErrors.first as? ActionFailure)
        #expect(failure.message == "An item may be in use. Quit the app that uses it and try again.")
    }

    @Test func aHotkeyLaunchStillAsks() async throws {
        let system = SystemHarness(trashItems: 3)
        try await system.harness.run("empty-trash", launch: .hotkey)
        #expect(system.harness.confirmations.count == 1)
    }

    @Test func openTrashShowsTheTrashInFinderAndAsksNothing() async throws {
        let system = SystemHarness(trashItems: 2)
        let outcome = try await system.harness.run("open-trash")
        #expect(outcome.kind == .close(hud: nil))
        let opened = try #require(system.fakes.workspace.opened.first)
        #expect(opened.lastPathComponent == ".Trash")
        #expect(opened.deletingLastPathComponent().path == system.fakes.storage.homeDirectory.path)
        #expect(system.harness.confirmations.isEmpty)
        #expect(system.housekeeping.requests.isEmpty)
    }

    @Test func onlyTrashFoldersCountAsTrash() {
        #expect(LiveHousekeeping.isTrashFolder(URL(filePath: "/Users/example/.Trash")))
        #expect(LiveHousekeeping.isTrashFolder(URL(filePath: "/Volumes/Example Drive/.Trashes/501")))
        #expect(!LiveHousekeeping.isTrashFolder(URL(filePath: "/Users/example")))
        #expect(!LiveHousekeeping.isTrashFolder(URL(filePath: "/")))
        #expect(!LiveHousekeeping.isTrashFolder(URL(filePath: "/Volumes/Example Drive")))
    }
}

@Suite("Trash folder guard", .timeLimit(.minutes(1)))
struct TrashFolderGuardTests {
    @Test func aTrashThatIsALinkToAnotherFolderIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "system-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "Elsewhere")
        let realTrash = root.appending(path: "home/.Trash")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realTrash, withIntermediateDirectories: true)
        let linkedTrash = root.appending(path: "other/.Trash")
        try FileManager.default.createDirectory(
            at: linkedTrash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedTrash, withDestinationURL: elsewhere)
        #expect(LiveHousekeeping.isSafeTrashFolder(realTrash))
        #expect(!LiveHousekeeping.isSafeTrashFolder(linkedTrash))
    }
}

@Suite("Eject All Disks", .timeLimit(.minutes(1)))
@MainActor
struct EjectTests {
    @Test func asksWithTheNamesThenEjectsEachWholeDrive() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        let outcome = try await system.harness.run("eject-all-disks")
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Eject 2 disks?")
        #expect(confirmation.message == "This ejects Example Drive and Example Backup.")
        #expect(confirmation.confirmTitle == "Eject")
        #expect(confirmation.suppressionKey == "eject-all")
        #expect(
            system.housekeeping.requests == [
                .eject(path: "/Volumes/Example Drive", keepingOtherPartitions: false),
                .eject(path: "/Volumes/Example Backup", keepingOtherPartitions: false),
            ])
        #expect(outcome.kind == .close(hud: .success("Ejected Example Drive and Example Backup")))
        #expect(system.harness.isClosed)
    }

    @Test func serversStayConnectedUnlessTheSettingSaysOtherwise() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.server])
        try await system.harness.run("eject-all-disks")
        #expect(system.harness.confirmations.first?.title == "Eject 1 disk?")
        #expect(system.housekeeping.disks == [SystemHarness.server])

        let again = SystemHarness(disks: [SystemHarness.drive, SystemHarness.server])
        again.settings[SystemSettings.ejectsNetworkVolumes] = true
        try await again.harness.run("eject-all-disks")
        #expect(again.housekeeping.disks.isEmpty)
    }

    @Test func aKeptDiskStaysAndShieldsItsDrive() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        system.settings[SystemSettings.neverEject] = ["example BACKUP"]
        try await system.harness.run("eject-all-disks")
        #expect(system.harness.confirmations.first?.message == "This ejects Example Drive.")
        #expect(system.housekeeping.requests == [.eject(path: "/Volumes/Example Drive", keepingOtherPartitions: true)])
        #expect(system.housekeeping.disks == [SystemHarness.backup])
    }

    @Test func nothingToEjectSaysSoWithoutAsking() async throws {
        let system = SystemHarness(disks: [SystemHarness.server])
        let outcome = try await system.harness.run("eject-all-disks")
        #expect(outcome.kind == .close(hud: "There are no disks to eject"))
        #expect(system.harness.confirmations.isEmpty)
    }

    @Test func decliningEjectsNothing() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive])
        system.harness.confirmationAnswer = false
        try await system.harness.run("eject-all-disks")
        #expect(system.housekeeping.requests.isEmpty)
    }

    @Test func aDiskInUseIsNamedAndTheRestStillEject() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        system.housekeeping.makeBusy(SystemHarness.drive.path)
        try await system.runShowingErrors("eject-all-disks")
        #expect(system.failureHUDs == ["Could not eject Example Drive"])
        #expect(system.housekeeping.disks == [SystemHarness.drive])
    }

    @Test func choosingDisksIsPure() {
        let disks = [SystemHarness.drive, SystemHarness.backup, SystemHarness.server]
        #expect(SystemFeature.disksToEject(disks, ejectsNetwork: false, keep: []) == [disks[0], disks[1]])
        #expect(
            SystemFeature.disksToEject(disks, ejectsNetwork: true, keep: ["example drive"]) == [disks[1], disks[2]])
    }

    @Test func theStartupDiskIsNeverEjected() {
        #expect(!LiveHousekeeping.canEject(path: "/"))
        #expect(!LiveHousekeeping.canEject(path: "/System/Volumes/Data"))
        #expect(LiveHousekeeping.canEject(path: "/Volumes/Example Drive"))
    }
}

@Suite("Toggle Hidden Files", .timeLimit(.minutes(1)))
@MainActor
struct HiddenFilesTests {
    @Test func turnsHiddenFilesOnThenOff() async throws {
        let system = SystemHarness()
        try await system.harness.run("toggle-hidden-files")
        #expect(system.housekeeping.hiddenFilesShown)
        try await system.harness.run("toggle-hidden-files")
        #expect(!system.housekeeping.hiddenFilesShown)
        #expect(system.harness.huds == ["Finder now shows hidden files", "Finder now hides hidden files"])
        #expect(system.housekeeping.requests == [.setShowsHiddenFiles(true), .setShowsHiddenFiles(false)])
    }

    @Test func readsFindersSettingInEachForm() {
        #expect(LiveHousekeeping.isOn(true as NSNumber))
        #expect(LiveHousekeeping.isOn("YES" as NSString))
        #expect(LiveHousekeeping.isOn("1" as NSString))
        #expect(!LiveHousekeeping.isOn("NO" as NSString))
        #expect(!LiveHousekeeping.isOn(nil))
    }
}
