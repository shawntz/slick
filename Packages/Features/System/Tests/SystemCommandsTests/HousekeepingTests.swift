import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

@Suite("Empty Trash", .timeLimit(.minutes(1)))
@MainActor
struct EmptyTrashTests {
    @Test func asksWithFindersCountThenEmptiesWithThePanelClosed() async throws {
        let system = SystemHarness(trashItems: 12)
        let outcome = try await system.harness.run("empty-trash")
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Empty the Trash?")
        #expect(confirmation.message == "The 12 items in the Trash will be deleted forever. You can't undo this.")
        #expect(confirmation.confirmTitle == "Empty Trash")
        #expect(confirmation.isDestructive)
        #expect(confirmation.suppressionKey == nil)
        #expect(system.housekeeping.requests == [.emptyTrash])
        #expect(outcome.kind == .close(hud: .success("Deleted 12 Items from the Trash")))
        #expect(system.housekeeping.trashItems == 0)
    }

    @Test func oneItemReadsAsOne() async throws {
        let system = SystemHarness(trashItems: 1)
        try await system.harness.run("empty-trash")
        #expect(
            system.harness.confirmations.first?.message
                == "The item in the Trash will be deleted forever. You can't undo this.")
        #expect(system.harness.huds == [.success("Deleted 1 Item from the Trash")])
    }

    @Test func withoutACountTheQuestionAsksWithoutOne() async throws {
        let system = SystemHarness(trashItems: 4)
        system.housekeeping.setCountsTrash(false)
        let outcome = try await system.harness.run("empty-trash")
        #expect(
            system.harness.confirmations.first?.message
                == "Every item in the Trash will be deleted forever. You can't undo this.")
        #expect(system.housekeeping.requests == [.emptyTrash])
        #expect(outcome.kind == .close(hud: .success("Emptied the Trash")))
    }

    @Test func anEmptyTrashSaysSoWithoutAsking() async throws {
        let system = SystemHarness()
        let outcome = try await system.harness.run("empty-trash")
        #expect(outcome.kind == .close(hud: "The Trash Is Already Empty"))
        #expect(system.harness.confirmations.isEmpty)
        #expect(system.housekeeping.requests.isEmpty)
    }

    @Test func decliningEmptiesNothing() async throws {
        let system = SystemHarness(trashItems: 4)
        system.harness.confirmationAnswer = false
        let outcome = try await system.harness.run("empty-trash")
        #expect(outcome.kind == .keepOpen)
        #expect(system.housekeeping.requests.isEmpty)
        #expect(system.housekeeping.trashItems == 4)
    }

    @Test func itNeedsAutomationForFinderAndNeverFullDiskAccess() async throws {
        let system = SystemHarness(trashItems: 2)
        system.fakes.permissions.set(.fullDiskAccess, to: .denied)
        try await system.harness.run("empty-trash")
        #expect(system.housekeeping.requests == [.emptyTrash], "Full Disk Access plays no part")
        #expect(!SystemFeature.manifest.permissions.map(\.permission).contains(.fullDiskAccess))

        let blocked = SystemHarness(trashItems: 2)
        blocked.housekeeping.failTrash(with: .permissionMissing(.automation(bundleID: "com.apple.finder")))
        await #expect(throws: HarnessError.permissionRequired([.automation(bundleID: "com.apple.finder")])) {
            try await blocked.harness.run("empty-trash")
        }
        #expect(blocked.harness.confirmations.isEmpty, "the card comes before the question")
    }

    @Test func aLargeTrashSaysFinderIsStillEmptying() async throws {
        let system = SystemHarness(trashItems: 5)
        system.housekeeping.setFinishesEmptying(false)
        let outcome = try await system.harness.run("empty-trash")
        #expect(outcome.kind == .close(hud: "Finder Is Still Emptying the Trash"))
    }

    @Test func withoutFinderItSaysSo() async throws {
        let system = SystemHarness(trashItems: 5)
        system.housekeeping.failTrash(with: .notFound)
        try await system.runShowingErrors("empty-trash")
        let failure = try #require(system.harness.actionErrors.first as? ActionFailure)
        #expect(failure.title == "Finder Is Not Running")
        #expect(system.housekeeping.requests.isEmpty)
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
}

/// The Apple Events the live service sends Finder, built but never sent.
@Suite("Finder events", .timeLimit(.minutes(1)))
struct FinderEventTests {
    /// This test process, so the events address nothing else. Nothing is sent.
    private let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)

    @Test func countAsksForTheItemsOfTheTrash() throws {
        let event = LiveHousekeeping.countEvent(to: target)
        #expect(event.eventClass == AEEventClass(kAECoreSuite))
        #expect(event.eventID == AEEventID(kAECountElements))
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyAEObjectClass))?.typeCodeValue == fourCharCode("cobj"))
        try expectTrash(event.paramDescriptor(forKeyword: keyDirectObject))
    }

    @Test func emptyIsFindersEmptyEventOnTheTrash() throws {
        let event = LiveHousekeeping.emptyEvent(to: target)
        #expect(event.eventClass == fourCharCode("fndr"))
        #expect(event.eventID == fourCharCode("empt"))
        try expectTrash(event.paramDescriptor(forKeyword: keyDirectObject))
    }

    @Test func theWarningIsAPropertyOfTheTrash() throws {
        let warns = LiveHousekeeping.warnsBeforeEmptying
        #expect(warns.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == fourCharCode("warn"))
        try expectTrash(warns.forKeyword(AEKeyword(keyAEContainer)))
    }

    /// The trash property (trsh) of the application, which is the null descriptor.
    private func expectTrash(_ specifier: NSAppleEventDescriptor?) throws {
        let specifier = try #require(specifier)
        #expect(specifier.descriptorType == DescType(typeObjectSpecifier))
        #expect(specifier.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == DescType(cProperty))
        #expect(specifier.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == fourCharCode("trsh"))
        #expect(specifier.forKeyword(AEKeyword(keyAEContainer))?.descriptorType == DescType(typeNull))
    }

    private func fourCharCode(_ text: String) -> FourCharCode {
        AppleEvents.fourCharCode(text)
    }
}

@Suite("Eject All Disks", .timeLimit(.minutes(1)))
@MainActor
struct EjectTests {
    @Test func asksWithTheNamesThenEjectsEachWholeDrive() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        let outcome = try await system.harness.run("eject-all-disks")
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Eject 2 Disks?")
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
        #expect(system.harness.confirmations.first?.title == "Eject 1 Disk?")
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
        #expect(outcome.kind == .close(hud: "No Disks to Eject"))
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
        #expect(system.failureHUDs == ["Could Not Eject Example Drive"])
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
        #expect(system.harness.huds == ["Finder Now Shows Hidden Files", "Finder Now Hides Hidden Files"])
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
