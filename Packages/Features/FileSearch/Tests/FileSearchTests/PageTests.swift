import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Search Files page", .timeLimit(.minutes(1)))
@MainActor
struct PageTests {
    @Test func thePageSearchesFiltersByKindAndPreviews() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        let page = try #require(fixture.harness.page)
        #expect(page.dropdown?.options.map(\.id) == ["all"] + FileKind.allCases.map(\.rawValue))
        #expect(page.emptyState?.title == "No Recent Files")
        #expect(page.notice?.title == "Desktop, Documents and Downloads Are Not Searched")

        try await fixture.harness.setQuery("a")
        let everything = fixture.harness.rows.map(\.title)
        #expect(everything.contains("beach.jpg") && everything.contains("Archive"))
        try await fixture.harness.setFilter("images")
        #expect(fixture.harness.rows.map(\.title) == ["beach.jpg"])
        try await fixture.harness.setFilter("folders")
        #expect(fixture.harness.rows.allSatisfy { FileRows.item(of: $0).isFolder && !FileRows.item(of: $0).isPackage })
        #expect(fixture.harness.rows.map(\.title).contains("Archive"))
        try await fixture.harness.setFilter("applications")
        try await fixture.harness.setQuery("to")
        #expect(fixture.harness.rows.map(\.title) == ["Tool.app"])
        try await fixture.harness.setFilter("all")

        try await fixture.harness.setQuery("notes")
        let row = try #require(fixture.harness.selectedRow)
        #expect(row.accessories.count == 1, "the page shows when the file last changed")
        let detail = try #require(try await fixture.harness.loadDetail())
        #expect(detail.body == .preview(fixture.tree.url("notes.md")))
        #expect(
            detail.metadata == [
                .label("Kind", value: "Test kind"), .label("Size", value: "8 bytes"),
                .date("Created", Date(timeIntervalSince1970: 1_790_000_000)),
                .date("Modified", Date(timeIntervalSince1970: 1_791_000_000)), .label("Where", value: "~"),
            ])
        #expect(fixture.fileSystem.factsRead == [fixture.tree.path("notes.md")], "only the selected row's facts")
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func noFactsAreReadOutsideTheScope() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let list = fixture.feature.searchList
        #expect(try await list.detail(for: fixture.bareRow("Desktop/desktop-shot.png")) == nil)
        #expect(try await list.detail(for: Row(id: ItemID(FileRows.namespace, "/etc/hosts"), title: "hosts")) == nil)
        #expect(fixture.fileSystem.factsRead.isEmpty)
    }

    @Test func browsingOnThePageAndAFolderOutsideTheIndex() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("~/Projects/")
        #expect(fixture.harness.sections.map(\.title) == ["~/Projects"])
        #expect(fixture.harness.rows.map(\.title) == ["app"])
        #expect(fixture.harness.rows.first?.completion == "~/Projects/app/")
        try await fixture.harness.setQuery("~/Desktop/")
        #expect(fixture.harness.rows.isEmpty)
        #expect(fixture.harness.page?.emptyState?.title == "Folder Not Searched")
        try await fixture.harness.setQuery("zzzqqq")
        #expect(fixture.harness.page?.emptyState?.title == "No Matching Files")
    }

    @Test func theNoticeOpensTheChoiceOfFolders() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        let action = try #require(fixture.harness.page?.notice?.action)
        #expect(action.title == "Choose Folders…")
        try await fixture.harness.perform(action, row: nil)
        #expect(fixture.harness.pages.count == 2)
        #expect(fixture.harness.sections.map(\.title) == ["Folders", "Volumes"])
        #expect(fixture.harness.rows.count == 7)
        #expect(fixture.harness.rows.allSatisfy { $0.memory == .never })
        #expect(fixture.fakes.permissions.requests.isEmpty, "opening the page asks for nothing")
        fixture.harness.pop()
        // Once Desktop is the only one left, the notice names it alone.
        fixture.feature.includePlaces([.documents, .downloads])
        fixture.fakes.permissions.set(.protectedFolder(.documents), to: .granted)
        fixture.fakes.permissions.set(.protectedFolder(.downloads), to: .granted)
        try await fixture.idle()
        try await fixture.harness.reloadPage()
        #expect(fixture.harness.page?.notice?.title == "Desktop Is Not Searched")
    }

    @Test func aFallbackOpensThePageWithTheTypedText() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let command = try fixture.harness.command("search")
        #expect(command.fallback?.title("notes") == "Search Files for \"notes\"")
        #expect(command.takesRootQueryOnTab)
        try await fixture.harness.runFallback("search", text: "notes")
        #expect(fixture.harness.page?.query == "notes")
        #expect(fixture.harness.rows.map(\.title) == ["notes.md"])
    }

    @Test func thePageWaitsForTheFirstWalk() async throws {
        let fixture = try Fixture()
        // Not activated: nothing is open yet.
        try await fixture.harness.run("search")
        #expect(fixture.harness.page?.emptyState?.title == "Building the File Index")
        #expect(try await fixture.harness.asyncSections(for: "notes").isEmpty)
    }
}
