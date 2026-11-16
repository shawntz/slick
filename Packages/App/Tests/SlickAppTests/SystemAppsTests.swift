import Foundation
import Host
import Kit
import KitHosting
import Platform
import Root
import Testing

@testable import SlickApp

/// A scenario with `"systemApps": true` lists only Apple's own apps from /System/Applications, by
/// their own names, and nothing of the person's: no app from /Applications or the home folder.
/// These tests read /System/Applications and nothing else on the Mac.
@Suite("System apps in scenarios", .timeLimit(.minutes(1)))
struct SystemAppsTests {
    @Test func readsOnlyTheSystemFolderAndItsSubfolders() {
        let entries = SystemApps.entries()
        #expect(!entries.isEmpty)
        let prefix = SystemApps.folder.path(percentEncoded: false)
        #expect(entries.allSatisfy { $0.url?.path(percentEncoded: false).hasPrefix(prefix) == true })
        #expect(entries.contains { $0.bundleID == "com.apple.TextEdit" })
        // Utilities is one level down.
        #expect(entries.contains { $0.url?.path(percentEncoded: false).contains("/Utilities/") == true })
    }

    @Test func preparesTheAppsTreeAsALinkThatDeletingTheDataFolderRemoves() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "system-apps-\(UUID().uuidString)")
        try SystemApps.prepare(dataRoot: folder)
        // Twice is fine: a second run over the same folder finds the link.
        try SystemApps.prepare(dataRoot: folder)
        let tree = SystemApps.appsTree(in: folder)
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: tree.appending(path: "System/Applications").path)
        #expect(link == "/System/Applications")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.appending(path: "Applications").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: tree.appending(path: "tree-version").path))
        try FileManager.default.removeItem(at: folder)
        #expect(FileManager.default.fileExists(atPath: SystemApps.folder.appending(path: "TextEdit.app").path))
    }

    @Test func theAppsFeatureListsOnlyTheSystemsApps() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "system-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ScenarioMode.File(name: "x", timeLimit: 5, items: [], systemApps: true)
        var configuration = try ScenarioMode.configuration(for: file, dataRoot: folder)
        configuration.makesPanel = false
        configuration.rootStorage = .inMemory
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: false)
        #expect(await SelfTest.within(.seconds(20)) { await assembly.ready() })

        let apps = try #require(assembly.runtime.features.first { $0.id == "apps" })
        let rows = try await apps.catalogSources.first { $0.namespace == "app" }?.rows() ?? []
        let systemIDs = Set(SystemApps.entries().map(\.bundleID))
        #expect(!rows.isEmpty)
        let others = rows.filter { !systemIDs.contains($0.id.key) }.map(\.title)
        #expect(others.isEmpty, "apps from elsewhere: \(others)")
        // The made-up apps of other scenarios are not there.
        #expect(!rows.contains { $0.id.key.hasPrefix("com.example.") })

        let snapshot = assembly.root.update(query: "textedit")
        #expect(snapshot.rows.first?.id == ItemID("app", "com.apple.TextEdit"))
        #expect(snapshot.rows.first?.title == "TextEdit")
        assembly.root.end()
        await assembly.shutdown()
    }
}
