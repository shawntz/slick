import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Scope and protected places", .timeLimit(.minutes(1)))
@MainActor
struct PlaceTests {
    private let cloudDocs = "Library/Mobile Documents/com~apple~CloudDocs"

    @Test func activationIndexesHomeAndNothingThatPrompts() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        #expect(fixture.harness.issues.isEmpty)
        #expect(try await fixture.rootPaths("notes") == ["notes.md"])
        #expect(try await fixture.rootPaths("main.swift") == ["Projects/app/src/main.swift"])
        #expect(try await fixture.rootPaths("tool") == ["Tool.app"])
        for hidden in [
            "desktop-shot", "letter", "installer", "cloudnote", "index.js", "config", "secret", "cachefile",
            "Info.plist", "store.db",
        ] {
            #expect(try await fixture.rootPaths(hidden).isEmpty, "\(hidden)")
        }
        #expect(fixture.fakes.permissions.requests.isEmpty, "nothing asks at activation")
        #expect(fixture.fakes.permissions.openStreamCount == 0, "no permission is followed at idle")
        #expect(fixture.fileSystem.volumeReads == 0, "volumes are not even listed until chosen")
        #expect(fixture.fileSystem.listed.isEmpty, "no folder is listed from disk")
        #expect(
            fixture.fakes.fileWatcher.watchedDirectories == [
                URL(filePath: fixture.tree.home, directoryHint: .isDirectory)
            ])
        #expect(fixture.feature.status == nil)
    }

    @Test func choosingOneProtectedFolderAsksForItAndIndexesOnlyIt() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        fixture.harness.grantsMissingPermissions = true
        try await fixture.harness.run("choose-folders")
        #expect(fixture.harness.rows.map(\.title).prefix(2) == ["All Protected Folders", "Desktop Folder"])
        try fixture.harness.select(title: "Desktop Folder")
        #expect(fixture.harness.actions().map(\.title) == ["Search Desktop Folder"])
        try await fixture.harness.performPrimary()
        try await fixture.idle()
        #expect(fixture.fakes.permissions.requests == [.protectedFolder(.desktop)])
        #expect(fixture.harness.toasts.map(\.title) == ["Searching Desktop Folder"])
        #expect(fixture.feature.context.settings[FileSearchSettings.includedPlaces] == ["desktop"])
        #expect(try await fixture.rootPaths("desktop-shot") == ["Desktop/desktop-shot.png"])
        #expect(try await fixture.rootPaths("letter").isEmpty, "Documents still waits for its own choice")
        try await fixture.harness.reloadPage()
        try fixture.harness.select(title: "Desktop Folder")
        #expect(fixture.harness.selectedRow?.accessories == [.tag("Searched", color: .green)])
        #expect(fixture.harness.actions().map(\.title) == ["Stop Searching Desktop Folder"])
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func aChoiceWaitsForAccessThenFollowsTheGrant() async throws {
        let fixture = try Fixture()
        fixture.fakes.permissions.answer = .denied
        try await fixture.start()
        try await fixture.harness.pressSettingsButton("Search Documents Folder")
        try await fixture.idle()
        #expect(fixture.fakes.permissions.requests == [.protectedFolder(.documents)])
        #expect(fixture.feature.placeStates()[.documents] == .waitingForAccess)
        #expect(fixture.harness.toasts.map(\.title) == ["Documents Folder Needs Access"])
        #expect(fixture.feature.status?.title == "Documents Folder Is Not Searched")
        #expect(fixture.feature.status?.requires == [.protectedFolder(.documents)])
        #expect(fixture.feature.status?.message == "Documents Folder will be searched once you grant access.")
        try await fixture.harness.run("search")
        #expect(fixture.harness.page?.notice?.title == "Documents Folder Needs Access")
        #expect(fixture.fakes.permissions.openStreamCount == 1, "followed only while it is missing")
        #expect(try await fixture.rootPaths("letter").isEmpty)
        fixture.fakes.permissions.set(.protectedFolder(.documents), to: .granted)
        try await fixture.idle()
        #expect(try await fixture.rootPaths("letter") == ["Documents/letter.txt"])
        #expect(fixture.fakes.permissions.openStreamCount == 0)
        #expect(fixture.feature.status == nil)
    }

    @Test func allAtOnceAsksForEachFolderAfterOneQuestion() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("choose-folders")
        try fixture.harness.select(title: "All Protected Folders")
        try await fixture.harness.performPrimary()
        try await fixture.idle()
        #expect(fixture.harness.confirmations.map(\.title) == ["Search All Protected Folders?"])
        #expect(
            fixture.fakes.permissions.requests == [
                .protectedFolder(.desktop), .protectedFolder(.documents), .protectedFolder(.downloads),
                .protectedFolder(.iCloudDrive),
            ])
        #expect(
            fixture.feature.watchedRoots == [fixture.tree.home, fixture.tree.path(cloudDocs)],
            "iCloud Drive is watched as a root of its own")
        for (query, path) in [
            ("desktop-shot", "Desktop/desktop-shot.png"), ("letter", "Documents/letter.txt"),
            ("installer", "Downloads/installer.dmg"),
            ("cloudnote", cloudDocs + "/cloudnote.txt"),
        ] {
            #expect(try await fixture.rootPaths(query) == [path])
        }
        #expect(try await fixture.rootPaths("cachefile").isEmpty, "the rest of Library stays out")
    }

    @Test func fullDiskAccessAloneSearchesNothingNewAndSparesThePrompts() async throws {
        let fixture = try Fixture(granted: [.fullDiskAccess])
        fixture.fileSystem.volumes = MountedVolumes(removable: ["/Volumes/NotMounted"])
        try await fixture.start()
        // Granted for another feature, such as Safari bookmarks: File Search reads nothing more.
        for name in ["letter", "cloudnote", "desktop-shot", "installer"] {
            #expect(try await fixture.rootPaths(name).isEmpty, "\(name)")
        }
        #expect(fixture.fileSystem.listed.isEmpty, "nothing is listed")
        #expect(fixture.feature.placeStates()[.documents] == .notSearched)
        #expect(fixture.feature.placeStates()[.removableVolumes] == .notSearched)
        #expect(fixture.fileSystem.volumeReads == 0)
        #expect(fixture.feature.status == nil)
        // Choosing them all is one question, and Full Disk Access spares every prompt but iCloud Drive's.
        fixture.harness.confirmationAnswer = true
        try await fixture.harness.pressSettingsButton("Search All Protected Folders")
        try await fixture.idle()
        #expect(fixture.fakes.permissions.requests == [.protectedFolder(.iCloudDrive)])
        #expect(try await fixture.rootPaths("letter") == ["Documents/letter.txt"])
        #expect(try await fixture.rootPaths("cloudnote").count == 1)
        // Turning one off holds even with Full Disk Access.
        try await fixture.harness.pressSettingsButton("Stop Searching Documents Folder")
        try await fixture.idle()
        #expect(try await fixture.rootPaths("letter").isEmpty)
        #expect(fixture.feature.placeStates()[.documents] == .turnedOff)
        #expect(fixture.harness.toasts.map(\.title).last == "Stopped Searching Documents Folder")
    }

    @Test func aReadErrorIsAccessNotGrantedAndIsNeverRetried() async throws {
        let tree = try TestTree()
        #expect(chmod(tree.path("Desktop"), 0) == 0)
        let fixture = try Fixture(tree: tree, granted: [.protectedFolder(.desktop)]) { settings in
            settings[FileSearchSettings.includedPlaces] = ["desktop"]
        }
        try await fixture.start()
        #expect(fixture.feature.placeStates()[.desktop] == .accessDenied)
        #expect(fixture.feature.context.settings[FileSearchSettings.deniedPlaces] == ["desktop"])
        #expect(fixture.feature.status?.title == "Desktop Folder Is Not Searched")
        #expect(fixture.feature.status?.requires == [], "the permission reads granted, so there is nothing to grant")
        #expect(fixture.feature.status?.message?.hasSuffix("then choose it again.") == true)
        try await fixture.harness.run("search")
        #expect(fixture.harness.page?.notice?.title == "Desktop Folder Could Not Be Read")
        fixture.harness.pop()
        #expect(fixture.feature.controller.plan?.allows(tree.path("Desktop/a.png")) == false)
        let walks = fixture.maker.walks
        // An event below the refused folder never reaches the index, and nothing walks again.
        fixture.fakes.fileWatcher.simulateChange([tree.url("Desktop/desktop-shot.png")])
        try await fixture.idle()
        #expect(fixture.maker.walks == walks)
        #expect(!fixture.appliedPaths.contains { $0.hasPrefix("Desktop") })
        #expect(fixture.fakes.permissions.openStreamCount == 0)
        // Pressing the button again is a new choice: it reads the folder once more.
        #expect(chmod(tree.path("Desktop"), 0o755) == 0)
        try await fixture.harness.pressSettingsButton("Search Desktop Folder")
        try await fixture.idle()
        #expect(fixture.feature.placeStates()[.desktop] == .searched)
        #expect(try await fixture.rootPaths("desktop-shot") == ["Desktop/desktop-shot.png"])
        #expect(fixture.feature.status == nil)
    }

    @Test func aMissingICloudDriveIsReportedOnlyWhenAskedFor() async throws {
        let tree = try TestTree(files: ["notes.md"])
        let asked = try Fixture(tree: tree, granted: [.protectedFolder(.iCloudDrive)]) {
            $0[FileSearchSettings.includedPlaces] = ["icloud-drive"]
        }
        try await asked.start()
        #expect(asked.feature.placeStates()[.iCloudDrive] == .accessDenied)
        #expect(asked.feature.status?.title == "iCloud Drive Is Not Searched")
        await asked.harness.deactivate()

        let unasked = try Fixture(tree: try TestTree(files: ["notes.md"]), granted: [.fullDiskAccess])
        try await unasked.start()
        #expect(unasked.feature.placeStates()[.iCloudDrive] == .notSearched, "Full Disk Access alone asks for nothing")
        #expect(unasked.feature.status == nil)
        #expect(unasked.fileSystem.listed.isEmpty)
    }

    @Test func iCloudDriveWaitsForItsOwnGrantEvenWithFullDiskAccess() async throws {
        let fixture = try Fixture(granted: [.fullDiskAccess]) {
            $0[FileSearchSettings.includedPlaces] = ["icloud-drive"]
        }
        try await fixture.start()
        #expect(fixture.feature.placeStates()[.iCloudDrive] == .waitingForAccess)
        #expect(fixture.feature.status?.requires == [.protectedFolder(.iCloudDrive)])
        #expect(try await fixture.rootPaths("cloudnote").isEmpty)
        #expect(fixture.fakes.permissions.openStreamCount == 0, "its status changes only when the launcher asks")
        // The grant through the host's card reaches the feature, which brings iCloud Drive in.
        try await fixture.harness.grantInSettings(.protectedFolder(.iCloudDrive))
        try await fixture.idle()
        #expect(fixture.feature.placeStates()[.iCloudDrive] == .searched)
        #expect(try await fixture.rootPaths("cloudnote") == [cloudDocs + "/cloudnote.txt"])
        #expect(try await fixture.rootPaths("cachefile").isEmpty, "the rest of Library stays out")
        #expect(fixture.feature.status == nil)
    }

    @Test func aChosenVolumeKindListsVolumesAndWatchesThem() async throws {
        let fixture = try Fixture(granted: [.protectedFolder(.removableVolumes)])
        let stick = try TestTree(files: ["photo-on-stick.jpg"])
        fixture.fileSystem.volumes = MountedVolumes(removable: [stick.home])
        try await fixture.start()
        try await fixture.harness.run("choose-folders")
        try fixture.harness.select(title: "Removable Volumes")
        try await fixture.harness.performPrimary()
        try await fixture.idle()
        #expect(fixture.fileSystem.volumeReads >= 1)
        #expect(try await fixture.rootTitles("photo-on-stick") == ["photo-on-stick.jpg"])
        #expect(fixture.feature.watchedRoots == [fixture.tree.home, stick.home])
    }
}
