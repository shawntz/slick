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

    /// A link can run each command, after the panel's own question. None of them changes a file: every
    /// change is a row action, which no link can reach.
    @Test func deepLinksOnlyOpenPagesOrWalkAgain() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let before = try fixture.names(in: "")
        let commands = fixture.feature.commands
        #expect(commands.map(\.id) == ["search", "rebuild", "choose-folders"])
        let changes = ["rename", "duplicate", "compress", "move-to", "copy-to", "move-to-trash"]
        #expect(commands.allSatisfy { !changes.contains($0.id) && $0.rowActions == nil })
        #expect(commands.allSatisfy { $0.showsInRoot && $0.arguments.isEmpty })
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
        #expect(fixture.operations.made.isEmpty)
        #expect(try fixture.names(in: "") == before)
        #expect(fixture.harness.pendingIssues.isEmpty)
        #expect(fixture.harness.issues.isEmpty)
    }

    /// Rule 7: titles in title case without a full stop, everything else a sentence.
    @Test func everyTitleToastAndFailureFollowsTheHouseStyle() {
        let name = "notes.md"
        let titles =
            [
                Strings.Actions.getInfo, Strings.Actions.openInTerminal, Strings.Actions.rename,
                Strings.Actions.duplicate,
                Strings.Actions.compress, Strings.Actions.moveTo, Strings.Actions.copyTo, Strings.Actions.moveToTrash,
                Strings.Actions.movedToTrash, Strings.Actions.copySection, Strings.Actions.manageSection,
                Strings.Operations.renameTitle(name), Strings.Operations.renameButton, Strings.Operations.nameField,
                Strings.Operations.renamed(to: name), Strings.Operations.duplicating(name),
                Strings.Operations.duplicated(name), Strings.Operations.compressing(name),
                Strings.Operations.compressed(name), Strings.Operations.moving(name),
                Strings.Operations.moved(to: "Archive"),
                Strings.Operations.copying(name), Strings.Operations.copied(to: "Archive"),
            ] + [FileOperationKind.rename, .duplicate, .compress, .move, .copy, .trash].map(Strings.Operations.failure)
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            #expect(title.first?.isUppercase == true, "\(title)")
        }
        let errors: [FileOperationError] =
            [
                .missing, .nameTaken(name), .notAFolder, .alreadyThere, .intoItself, .notAllowed, .noSpace,
                .outsideTree,
                .failed(5),
            ]
            + [.empty, .dots, .slash, .colon, .control, .leadingDot, .tooLong].map {
                FileOperationError.invalidName($0)
            }
        var sentences = [
            Strings.Operations.copyNamed(name), Strings.Operations.archiveNamed(name),
            Strings.Operations.moveToPrompt(name), Strings.Operations.copyToPrompt(name),
            Strings.Operations.notSearched(name), Strings.Places.searchAllConfirmation.message ?? "",
            Strings.Permissions.iCloudDrive,
        ]
        for kind in [FileOperationKind.rename, .duplicate, .compress, .move, .copy, .trash] {
            sentences += errors.map { Strings.Operations.explain($0, kind: kind, item: name, folder: "Archive") }
        }
        for state in [PlaceState.searched, .notSearched, .waitingForAccess, .accessDenied, .turnedOff] {
            sentences += ProtectedPlace.allCases.map { Strings.Places.explanation($0, state) }
        }
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
            let opening =
                sentence.first?.isUppercase == true || sentence.hasPrefix("\u{201C}") || sentence.hasPrefix("macOS")
            #expect(opening, "\(sentence)")
            #expect(!sentence.contains("\u{2014}") && !sentence.contains("  "), "\(sentence)")
        }
        // Names someone else chose are shown on one line, cut, and never obeyed.
        #expect(Strings.Operations.renamed(to: "a\u{202E}fdp.app") == "Renamed to “a\u{FFFD}fdp.app”")
        #expect(Strings.Operations.duplicated(String(repeating: "x", count: 80)).count == "Duplicated “”".count + 60)
    }

    @Test func confirmationsUseTitleCase() {
        #expect(Strings.Places.searchAllConfirmation.title == "Search All Protected Folders?")
        #expect(
            Strings.Actions.trashQuestion(String(repeating: "a", count: 80)) == "Move “"
                + String(repeating: "a", count: 59) + "…” to the Trash?")
    }
}
