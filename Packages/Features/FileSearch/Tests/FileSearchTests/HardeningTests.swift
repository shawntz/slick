import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

/// What a second pass found: access taken away while running, floods of events, and names that
/// draw in a misleading way.
@Suite("Hardening", .timeLimit(.minutes(1)))
@MainActor
struct HardeningTests {
    @Test func accessTakenAwayWhileRunningStopsReadsAndWaitsForANewGrant() async throws {
        let fixture = try Fixture(granted: [.protectedFolder(.desktop)]) {
            $0[FileSearchSettings.includedPlaces] = ["desktop"]
        }
        try await fixture.start()
        #expect(try await fixture.rootPaths("desktop-shot") == ["Desktop/desktop-shot.png"])
        #expect(fixture.fakes.permissions.openStreamCount == 0, "nothing is followed while access is there")

        fixture.fakes.permissions.set(.protectedFolder(.desktop), to: .denied)
        try fixture.tree.write("Desktop/after-revoke.png")
        try fixture.tree.write("Projects/after-revoke.txt")
        let batchesBefore = fixture.maker.batches.count
        fixture.fakes.fileWatcher.simulateChange([
            fixture.tree.url("Desktop/after-revoke.png"), fixture.tree.url("Projects/after-revoke.txt"),
        ])
        try await fixture.idle()
        let applied = fixture.maker.batches.dropFirst(batchesBefore).flatMap { $0.map(\.path) }
        #expect(!applied.contains(fixture.tree.path("Desktop/after-revoke.png")), "nothing below Desktop is read")
        #expect(applied.contains(fixture.tree.path("Projects/after-revoke.txt")), "the rest of home still follows")
        #expect(fixture.feature.placeStates()[.desktop] == .waitingForAccess)
        #expect(try await fixture.rootPaths("desktop-shot").isEmpty, "the new scope leaves Desktop out")
        #expect(fixture.fakes.permissions.openStreamCount == 1, "a stream waits for the grant")
        #expect(fixture.fakes.permissions.requests.isEmpty, "nothing asks by itself")
        #expect(fixture.feature.status?.title == "Desktop Folder Is Not Searched")

        fixture.fakes.permissions.set(.protectedFolder(.desktop), to: .granted)
        try await fixture.idle()
        #expect(try await fixture.rootPaths("after-revoke").contains("Desktop/after-revoke.png"))
        #expect(fixture.fakes.permissions.openStreamCount == 0, "the stream ends at the grant")
    }

    @Test func churnInLibraryNeverWaitsInMemory() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let batches = fixture.maker.batches.count
        let urls = (0..<5_000).map { fixture.tree.url("Library/Caches/churn-\($0).db") }
        fixture.feature.controller.submit(urls)
        #expect(fixture.feature.controller.pendingCount == 0, "paths outside the scope are dropped on arrival")
        try await fixture.idle()
        #expect(fixture.maker.batches.count == batches)
    }

    @Test func aFloodOfEventsBecomesOneRescanOfTheRoots() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try fixture.tree.write("Projects/flood/missed.txt")
        let urls = (0...IndexController.pendingLimit).map { fixture.tree.url("Projects/flood/file-\($0).txt") }
        fixture.feature.controller.submit(urls)
        try await fixture.idle()
        let last = try #require(fixture.maker.batches.last)
        #expect(last.map(\.path) == [fixture.tree.home])
        #expect(last.map(\.flags) == [IndexController.mustScanSubDirs])
        #expect(try await fixture.rootPaths("missed") == ["Projects/flood/missed.txt"])
    }

    @Test func namesDrawOnOneLineInTheOrderTheyAreStored() async throws {
        let style = FileRows.Style(home: "/home")
        func row(_ name: String, highlights: [Range<Int>] = [0..<1]) -> Row {
            FileRows.row(path: "/home/" + name, flags: [], modified: nil, highlights: highlights, style: style)
        }
        #expect(row("two\u{2028}lines").title == "two lines")
        #expect(row("para\u{2029}graph").title == "para graph")
        #expect(row("tab\there").title == "tab here")
        #expect(row("photo\u{202E}gpj.app").title == "photo\u{FFFD}gpj.app")
        #expect(row("isolate\u{2067}x\u{2069}").title == "isolate\u{FFFD}x\u{FFFD}")
        #expect(row("photo\u{202E}gpj.app").title.utf16.count == "photo\u{202E}gpj.app".utf16.count)
        for blank in [" ", "\u{200B}", "\u{3000}", "\u{2028}"] {
            let shown = row(blank)
            #expect(shown.title == "Untitled Item", "\(blank.debugDescription)")
            #expect(shown.titleHighlights.isEmpty)
        }
        #expect(row("Untitled Item").titleHighlights == [0..<1], "a file really named so keeps its highlight")
        #expect(row("naïve 猫 مرحبا").title == "naïve 猫 مرحبا")
    }

    @Test func aMisleadingNameIsFoundAndShownAsStored() async throws {
        let fixture = try Fixture()
        try fixture.tree.write("Projects/invoice\u{202E}fdp.app")
        try await fixture.start()
        let rows = try await fixture.harness.asyncSections(for: "invoice").flatMap(\.rows)
        let row = try #require(rows.first)
        #expect(row.title == "invoice\u{FFFD}fdp.app")
        let trash = try #require(fixture.harness.rootActions(for: row).first { $0.id == "move-to-trash" })
        #expect(trash.confirmation?.title == "Move “invoice\u{FFFD}fdp.app” to the Trash?")
        #expect(trash.confirmation?.isDestructive == true)
    }

    @Test func deepLinksOnlyOpenPagesOrWalkAgain() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        for command in ["search", "choose-folders"] {
            let outcome = try await fixture.harness.run(command, launch: .deeplink)
            #expect(outcome.kind == .push, "\(command)")
            fixture.harness.pop()
        }
        _ = try await fixture.harness.run("rebuild", launch: .deeplink)
        try await fixture.idle()
        #expect(fixture.fakes.permissions.requests.isEmpty)
        #expect(fixture.fakes.workspace.trashed.isEmpty)
        #expect(fixture.feature.context.settings[FileSearchSettings.includedPlaces].isEmpty)
        #expect(fixture.harness.pendingIssues.isEmpty)
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func confirmationsUseTitleCase() {
        #expect(Strings.Places.searchAllConfirmation.title == "Search All Protected Folders?")
        #expect(Strings.Places.iCloudConfirmation.title == "Search iCloud Drive?")
        #expect(
            Strings.Actions.trashQuestion(String(repeating: "a", count: 80)) == "Move “"
                + String(repeating: "a", count: 59) + "…” to the Trash?")
    }
}
