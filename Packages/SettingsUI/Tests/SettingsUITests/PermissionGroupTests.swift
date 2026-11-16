import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

/// The permissions in groups, the line under Full Disk Access, and a request macOS leaves
/// unanswered, on the permissions step and in the Permissions pane.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PermissionGroupTests {
    @Test func everyPermissionHasItsGroupAndPlace() {
        let given: [Permission] = [
            .automation(bundleID: "com.example.player"), .protectedFolder(.networkVolumes), .contacts,
            .protectedFolder(.iCloudDrive), .pasteboard, .fullDiskAccess, .reminders, .screenRecording,
            .protectedFolder(.desktop), .accessibility, .calendars, .protectedFolder(.removableVolumes),
            .automation(bundleID: "com.example.finder"), .inputMonitoring, .protectedFolder(.downloads), .location,
            .protectedFolder(.documents),
        ]
        let grouped = PermissionGroup.grouped(given) { $0 }
        #expect(
            grouped.map(\.group.title) == [
                "Typing and Pasting", "Files and Folders", "Calendar and Contacts", "Other Apps",
            ])
        #expect(grouped[0].items == [.accessibility, .inputMonitoring, .pasteboard])
        #expect(
            grouped[1].items == [
                .fullDiskAccess, .protectedFolder(.desktop), .protectedFolder(.documents), .protectedFolder(.downloads),
                .protectedFolder(.iCloudDrive), .protectedFolder(.removableVolumes), .protectedFolder(.networkVolumes),
            ])
        #expect(grouped[2].items == [.calendars, .reminders, .contacts, .location])
        // Automation keeps the order features name it in, then Screen Recording.
        #expect(
            grouped[3].items == [
                .automation(bundleID: "com.example.player"), .automation(bundleID: "com.example.finder"),
                .screenRecording,
            ])
        // A group with nothing in it is left out.
        #expect(PermissionGroup.grouped([Permission.contacts]) { $0 }.map(\.group) == [.personal])
    }

    @Test func theFullDiskAccessLineShowsOnlyWithAFolderItAllows() {
        #expect(
            PermissionGroup.fullDiskAccessCoversFolders
                == "Allowing this also allows the folders below, except iCloud Drive.")
        #expect(PermissionGroup.listsFolderFullDiskAccessAllows([.fullDiskAccess, .protectedFolder(.downloads)]))
        #expect(!PermissionGroup.listsFolderFullDiskAccessAllows([.fullDiskAccess, .protectedFolder(.iCloudDrive)]))
        #expect(!PermissionGroup.listsFolderFullDiskAccessAllows([.fullDiskAccess]))
    }

    @Test func theStepListsPermissionsInGroups() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(FolderFeature.self, fakes: bed.fakes)
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.show(.permissions))
        #expect(
            model.permissionGroups.map(\.group) == [.typing, .files])
        #expect(
            model.permissionItems.map(\.permission) == [
                .accessibility, .inputMonitoring, .fullDiskAccess, .protectedFolder(.downloads),
                .protectedFolder(.iCloudDrive),
            ])
        #expect(bed.fakes.permissions.requests.isEmpty)
    }

    @Test func aRequestMacOSLeavesUnansweredShowsWhereToAllowIt() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(FolderFeature.self, fakes: bed.fakes)
        bed.fakes.permissions.answer = .notDetermined
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.show(.permissions))
        let iCloud = Permission.protectedFolder(.iCloudDrive)
        await model.allow(iCloud)
        let item = model.permissionItems.first { $0.permission == iCloud }
        #expect(item?.isAsking == false)
        #expect(
            item?.unansweredSentence
                == "macOS has not answered yet. You can allow it in System Settings, under Privacy & Security, Files & Folders."
        )
        // The button beside it opens that place.
        await model.openSettings(for: iCloud)
        #expect(bed.fakes.permissions.openedSettings == [iCloud])
        // Once it is allowed, the row says so instead.
        bed.fakes.permissions.set(iCloud, to: .granted)
        #expect(model.permissionItems.first { $0.permission == iCloud }?.unansweredSentence == nil)
        #expect(model.permissionItems.first { $0.permission == iCloud }?.status == .granted)
    }

    @Test func anAnswerShowsWithoutTheSentence() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(FolderFeature.self, fakes: bed.fakes)
        bed.fakes.permissions.answer = .denied
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.show(.permissions))
        await model.allow(.protectedFolder(.downloads))
        let item = model.permissionItems.first { $0.permission == .protectedFolder(.downloads) }
        #expect(item?.unansweredSentence == nil)
        #expect(item?.status == .denied)
    }

    @Test func aLateAnswerShowsWhileTheStepWatches() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(FolderFeature.self, fakes: bed.fakes)
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.show(.permissions))
        let watching = Task { await model.watchPermissions() }
        #expect(await eventually { bed.fakes.permissions.openStreamCount == 5 })
        bed.fakes.permissions.set(.protectedFolder(.downloads), to: .granted)
        await bed.fakes.permissions.settle()
        #expect(model.permissionItems.first { $0.permission == .protectedFolder(.downloads) }?.status == .granted)
        #expect(bed.directory.announcedGrants == [.protectedFolder(.downloads)])
        watching.cancel()
        #expect(await eventually { bed.fakes.permissions.openStreamCount == 0 })
    }

    @Test func automationIsTitledByItsApp() {
        let bed = TestBed()
        bed.fakes.workspace.installed = [AppInfo(bundleID: "com.example.player", name: "Example Player")]
        let context = bed.context()
        #expect(context.title(for: .automation(bundleID: "com.example.player")) == "Example Player Automation")
        #expect(context.title(for: .automation(bundleID: "com.example.unknown")) == "Automation")
        // Apple's helpers outside the app folders, which the workspace does not list, keep their names.
        #expect(context.title(for: .automation(bundleID: "com.apple.finder")) == "Finder Automation")
        #expect(context.title(for: .automation(bundleID: "com.apple.systemevents")) == "System Events Automation")
        #expect(context.title(for: .automation(bundleID: "com.apple.loginwindow")) == "Login Window Automation")
        #expect(context.title(for: .contacts) == "Contacts")
    }

    @Test func thePaneListsTheSameGroups() {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(FolderFeature.self, fakes: bed.fakes)
        let model = PermissionsModel(context: bed.context())
        #expect(model.groups.map(\.group) == [.typing, .files, .otherApps])
        #expect(model.groups[1].entries.map(\.permission).first == .fullDiskAccess)
    }
}

/// A made-up feature that names folders and Full Disk Access in an order unlike the groups'.
final class FolderFeature: Feature {
    static let manifest = FeatureManifest(
        id: "folders", name: "Folder Finder", icon: .symbol("folder"),
        permissions: [
            PermissionNeed(.protectedFolder(.iCloudDrive), reason: "Search the files in iCloud Drive."),
            PermissionNeed(.protectedFolder(.downloads), reason: "Search the files in Downloads."),
            PermissionNeed(.fullDiskAccess, reason: "Search protected folders without a prompt for each."),
        ])

    init(context: FeatureContext) {}
}
