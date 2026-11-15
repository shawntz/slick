import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Root search and browsing", .timeLimit(.minutes(1)))
@MainActor
struct RootSearchTests {
    @Test func namesFillALimitedFilesSectionFromTwoCharacters() async throws {
        let tree = try TestTree(files: (1...9).map { "Reports/report-\($0).txt" } + ["notes.md"])
        let fixture = try Fixture(tree: tree)
        try await fixture.start()
        let sections = try await fixture.harness.asyncSections(for: "report")
        #expect(sections.map(\.title) == ["Files"])
        #expect(sections.first?.rows.count == 5)
        #expect(try await fixture.harness.asyncSections(for: "r").isEmpty, "one character is not sent")
        let row = try #require(try await fixture.harness.asyncSections(for: "notes").first?.rows.first)
        #expect(row.title == "notes.md" && row.subtitle == "~")
        #expect(row.titleHighlights == [0..<5])
        #expect(row.icon == .file(path: tree.path("notes.md")))
        #expect(row.represents == .files([tree.url("notes.md")]))
        #expect(row.quickLookURL == tree.url("notes.md"))
        #expect(row.completion == nil, "a file has nothing to descend into")
        #expect(row.memory == .remember)
        let folder = try #require(try await fixture.harness.asyncSections(for: "Reports").first?.rows.first)
        #expect(folder.completion == "~/Reports/", "Tab from a search descends into the folder")
    }

    @Test func aPathTakesOverAndTabWalksDownIt() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let provider = fixture.feature.rootFiles
        #expect(provider.takesOver("~/") && provider.takesOver("/x") && provider.takesOver("~"))
        #expect(!provider.takesOver("notes") && !provider.takesOver(""))
        #expect(provider.debounce(for: "~/") == .zero)
        #expect(provider.sectionTitle(for: "~/Proj") == "~" && provider.sectionTitle(for: "notes") == "Files")

        let home = try await fixture.harness.asyncSections(for: "~/")
        #expect(home.map(\.title) == ["~"])
        let names = home.flatMap(\.rows).map(\.title)
        #expect(names.contains("Projects") && names.contains("notes.md") && names.contains("Tool.app"))
        #expect(!names.contains("Library") && !names.contains("Desktop") && !names.contains(".hidden-config"))
        let projects = try #require(home.flatMap(\.rows).first { $0.title == "Projects" })
        let next = try await fixture.harness.pressTab("~/", on: projects)
        #expect(next == "~/Projects/")
        let app = try #require(try await fixture.harness.asyncSections(for: "~/Projects/").first?.rows.first)
        #expect(app.title == "app")
        #expect(try await fixture.harness.pressTab("~/Projects/", on: app) == "~/Projects/app/")
        let inside = try await fixture.harness.asyncSections(for: "~/Projects/app/")
        #expect(inside.map(\.title) == ["~/Projects/app"])
        #expect(Set(inside.flatMap(\.rows).map(\.title)) == ["src", "README.md"])
        #expect(try await fixture.rootTitles("~/Projects/app/RE") == ["README.md"], "the rest filters the listing")
        let tool = try #require(home.flatMap(\.rows).first { $0.title == "Tool.app" })
        #expect(tool.completion == nil, "an app is opened, not browsed")
    }

    @Test func anAbsolutePathCompletesAsAnAbsolutePath() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let rows = try await fixture.harness.asyncSections(for: fixture.tree.home + "/Pro").flatMap(\.rows)
        #expect(rows.map(\.title) == ["Projects"])
        #expect(rows.first?.completion == fixture.tree.home + "/Projects/")
    }

    @Test func aFolderOutsideTheIndexListsNothing() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        #expect(try await fixture.harness.asyncSections(for: "~/Desktop/").isEmpty, "never read before it is chosen")
        #expect(try await fixture.harness.asyncSections(for: "/nonexistent-folder/").isEmpty)
    }

    @Test func excludedPatternsAndHiddenFilesFollowTheSettings() async throws {
        let tree = try TestTree(files: ["build.log", "notes.md", "dist/bundle.js", ".env-sample"])
        let fixture = try Fixture(tree: tree) { $0[FileSearchSettings.excludedNames] = ["*.log", "dist"] }
        try await fixture.start()
        #expect(try await fixture.rootTitles("build").isEmpty)
        #expect(try await fixture.rootTitles("bundle").isEmpty)
        #expect(try await fixture.rootTitles("env-sample").isEmpty)
        fixture.feature.context.settings[FileSearchSettings.includesHidden] = true
        try await fixture.idle()
        #expect(try await fixture.rootTitles("env-sample") == [".env-sample"])
        fixture.feature.context.settings[FileSearchSettings.excludedNames] = []
        try await fixture.idle()
        #expect(try await fixture.rootTitles("build.log") == ["build.log"])
        #expect(try await fixture.rootTitles("bundle") == ["bundle.js"])
    }

    @Test func theRootSwitchRemovesTheProvider() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        #expect(fixture.feature.liveProviders.count == 1)
        fixture.feature.context.settings[FileSearchSettings.showsInRoot] = false
        try await fixture.idle()
        #expect(fixture.feature.liveProviders.isEmpty)
        #expect(try await fixture.harness.asyncSections(for: "notes").isEmpty)
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func rememberedRowsAreCheckedAgainstTheIndexNotTheDisk() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let kept = fixture.bareRow("notes.md").id
        let gone = fixture.bareRow("deleted-long-ago.txt").id
        let blocked = fixture.bareRow("Desktop/desktop-shot.png").id
        let elsewhere = ItemID(FileRows.namespace, "/Volumes/Unplugged/movie.mov")
        let existing = await fixture.feature.rootFiles.existingItems(among: [kept, gone, blocked, elsewhere])
        #expect(existing == [kept, elsewhere])
    }

    @Test func aStaleSearchIsDroppedWhenANewerOneArrives() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let provider = fixture.feature.rootFiles
        async let first = provider.results(for: "notes")
        async let second = provider.results(for: "report")
        let results = await (try? first, try? second)
        #expect(results.1?.map(\.title) == ["report-2024.pdf"])
        #expect(results.0 == nil || results.0?.map(\.title) == ["notes.md"])
    }
}
