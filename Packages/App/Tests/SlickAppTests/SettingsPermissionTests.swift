import Foundation
import Kit
import Platform
import Root
import SettingsUI
import Testing

@testable import SlickApp

/// The settings window asks Platform whether an Automation permission waits for its app. SettingsUI's
/// own default says every one waits, which would hide Allow for Finder and System Events too.
@Suite("Settings permissions", .timeLimit(.minutes(1)))
struct SettingsPermissionTests {
    @Test func settingsAskPlatformWhetherAnAutomationPermissionWaitsForItsApp() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = Assembly(
            .init(environment: .selftest, dataRoot: folder.url, rootStorage: .inMemory, makesPanel: false))
        let permissions: [Permission] = [
            .automation(bundleID: "com.apple.finder"), .automation(bundleID: "com.apple.systemevents"),
            .automation(bundleID: "com.example.player"), .accessibility,
        ]
        for permission in permissions {
            let platformAnswer = assembly.platform.permissions.waitsForApp(permission)
            #expect(assembly.dependencies.permissionWaitsForApp(permission) == platformAnswer, "\(permission)")
        }
        // Outside live, Platform's permission system never waits, where the default would.
        #expect(!assembly.dependencies.permissionWaitsForApp(.automation(bundleID: "com.apple.finder")))
        await assembly.shutdown()
    }
}
