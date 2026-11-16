import Foundation
import SettingsUI
import Testing

@testable import SlickApp

/// The About pane links the repository, the website, the license, the notices and the security
/// policy, and the settings window gets them from the assembly.
@Suite("Project links", .serialized, .timeLimit(.minutes(1)))
struct ProjectLinksTests {
    @Test func theAboutPaneLinksWhereTheProjectLives() {
        #expect(
            ProjectLinks.about.map(\.title) == [
                "Repository", "Website", "License", "Third-Party Notices", "Security Policy",
            ])
        #expect(ProjectLinks.about.allSatisfy { $0.url.scheme == "https" && $0.url.host() != nil })
        let repository = ProjectLinks.repository.absoluteString
        #expect(ProjectLinks.about.filter { $0.url.absoluteString.hasPrefix(repository + "/") }.count == 3)
        // The files the links name exist in this checkout.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..")
            .standardizedFileURL
        for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "SECURITY.md"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: name).path), "\(name)")
        }
    }

    @MainActor @Test func theSettingsWindowGetsThem() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "project-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let file = ScenarioMode.File(name: "x", timeLimit: 5, items: [])
        var configuration = try ScenarioMode.configuration(for: file, dataRoot: data)
        configuration.makesPanel = false
        let assembly = Assembly(configuration)
        #expect(assembly.dependencies.about.links == ProjectLinks.about)
        await assembly.shutdown()
    }
}
