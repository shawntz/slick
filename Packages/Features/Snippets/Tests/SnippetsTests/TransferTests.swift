import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import Snippets

@Suite("Import and export", .timeLimit(.minutes(1)))
struct TransferTests {
    private let all = [Fixture.greeting, Fixture.signoff, Fixture.address, Fixture.bug]

    /// A file in the fake storage folder, never in the user's folders.
    private func exchangeFile(_ harness: FeatureHarness<SnippetsFeature>, _ name: String = "exchange.json") -> URL {
        harness.fakes.storage.root.appending(path: name)
    }

    @Test func exportThenImportRoundTrips() async throws {
        let source = try await FeatureHarness.loaded(
            all + [Fixture.snippet("Quiet", "q", keyword: "qq", expands: false)])
        let file = exchangeFile(source)
        source.fakes.fileDialogs.saveLocation = file
        try await source.run(SnippetIDs.exportCommand)
        #expect(source.huds == [HUD("Exported 5 Snippets", style: .success)])
        let request = try #require(source.fakes.fileDialogs.saveRequests.first)
        #expect(request.suggestedName == "Snippets.json")
        #expect(request.allowedTypes == ["json"])

        // The file has the shape Raycast reads: a list of objects with name, text and keyword.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        #expect(raw?.first?["name"] as? String == "Greeting")
        #expect(raw?.first?["text"] as? String == "Hello there")
        #expect(raw?.first?["keyword"] as? String == "hi")
        #expect(raw?.first?["id"] == nil, "IDs stay local")

        let target = try await FeatureHarness.loaded([])
        try await target.importAndConfirm([file])
        #expect(target.toasts.last?.title == "Imported 5 Snippets")
        #expect(target.toasts.last?.message == nil)
        #expect(target.page == nil, "confirming goes back")
        func fields(_ snippets: [Snippet]) -> [String] {
            snippets.map {
                "\($0.name)|\($0.text)|\($0.keyword ?? "-")|\($0.collection ?? "-")|\($0.expands)|\($0.isPinned)"
            }
        }
        #expect(fields(target.library.index.snippets) == fields(source.library.index.snippets))
        #expect(target.library.index.snippets.allSatisfy { $0.created == target.fakes.clock.now })

        // Importing the same file again shows no page: nothing is new.
        target.fakes.fileDialogs.filesToChoose = [file]
        try await target.run(SnippetIDs.importCommand)
        #expect(target.page == nil)
        #expect(target.toasts.last?.title == "No New Snippets to Import")
        #expect(target.toasts.last?.message == "Skipped 5 snippets you already have.")
        #expect(target.library.index.snippets.count == 5)
    }

    @Test func thePageSaysWhatHappensBeforeAnythingIsSaved() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting, Fixture.signoff])
        let file = exchangeFile(harness)
        try write(
            """
            [
              {"name": "Greeting", "text": "Hello there", "keyword": "hi"},
              {"name": "Hello Again", "text": "Hello there", "keyword": "hi"},
              {"name": "Other Sig", "text": "Different", "keyword": "sig"},
              {"name": "Greeting", "text": "A different greeting"},
              {"name": "No Text"},
              {"text": "No name"},
              {"name": "Blank", "text": "   "},
              42,
              {"name": "Fresh", "text": "Fresh {browser-tab}", "keyword": 7, "collection": "Imported"}
            ]
            """, to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.run(SnippetIDs.importCommand)

        #expect(harness.importPage != nil)
        #expect(
            harness.importSections == [
                "add": ["Greeting 2", "Fresh"], "without-keyword": ["Other Sig"],
                "duplicate": ["Greeting", "Hello Again"], "not-valid": ["No Text", "Entry 6", "Blank", "Entry 8"],
            ])
        #expect(
            harness.sections.map(\.title) == [
                "To Add", "To Add Without Their Keywords", "Skipped as Duplicates", "Skipped as Not Valid",
            ])
        #expect(harness.sections.allSatisfy { $0.showsCount })
        #expect(harness.page?.notice?.title == "Nothing Is Saved Until You Import")
        #expect(harness.library.index.snippets.count == 2, "nothing is saved yet")
        #expect(try await harness.storedSnippets().count == 2)

        func subtitle(_ title: String) -> String? { harness.rows.first { $0.title == title }?.subtitle }
        #expect(subtitle("Other Sig") == "“sig” is already the keyword of “Sign Off”, so this one is added without it.")
        #expect(subtitle("Greeting 2") == "Renamed, because a snippet is already called “Greeting”.")
        #expect(subtitle("Fresh") == "{browser-tab} stays as typed, because nothing here fills it in.")
        #expect(subtitle("Hello Again") == "“Greeting” already has this keyword and text.")
        #expect(subtitle("Entry 6") == "It has no name.")
        #expect(subtitle("Blank") == "It has no text.")

        try harness.select(title: "Fresh")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.metadata.contains(.tags("Stays as Typed", [Tag("{browser-tab}", color: .orange)])))
        #expect(detail.metadata.contains(.label("Collection", value: "Imported", icon: .symbol("folder"))))
        try harness.select(title: "Other Sig")
        let other = try #require(try await harness.loadDetail())
        #expect(other.metadata.contains(.label("Keyword in File", value: "sig")))

        #expect(harness.actions().map(\.title) == ["Import 3 Snippets"])
        try await harness.performPrimary()
        #expect(harness.toasts.last?.title == "Imported 3 Snippets")
        #expect(
            harness.toasts.last?.message
                == "Imported 1 snippet without its keyword. Skipped 2 snippets you already have. "
                + "Skipped 4 entries that were not valid. Renamed 1 snippet whose name was taken. "
                + "1 snippet has placeholders that work differently here.")
        #expect(harness.page == nil)
        #expect(harness.snippet(named: "Sign Off")?.text == Fixture.signoff.text, "what the user has stays")
        #expect(harness.snippet(named: "Greeting")?.text == "Hello there")
        #expect(harness.snippet(named: "Greeting 2")?.text == "A different greeting")
        #expect(harness.snippet(named: "Other Sig")?.keyword == nil)
        let fresh = try #require(harness.snippet(named: "Fresh"))
        #expect(fresh.keyword == nil, "a keyword of the wrong type is dropped")
        #expect(fresh.collection == "Imported")
        #expect(try await harness.storedSnippets().count == 5)
        #expect(harness.issues.isEmpty)
    }

    @Test func confirmingDecidesAgainstTheSnippetsAsTheyAreThen() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let file = exchangeFile(harness)
        try write(#"[{"name": "Later", "text": "Later text", "keyword": "later"}]"#, to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.importSections == ["add": ["Later"]])

        // While the page shows, the user gives another snippet that keyword.
        try await harness.library.add(SnippetDraft(name: "Mine", text: "My text", keyword: "later"))
        try await harness.performPrimary()
        #expect(harness.snippet(named: "Mine")?.keyword == "later")
        #expect(harness.snippet(named: "Later")?.keyword == nil)
        #expect(harness.toasts.last?.message == "Imported 1 snippet without its keyword.")
    }

    @Test func importingTheSameEntryAgainAfterItLostItsKeywordAddsNothing() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.signoff])
        let file = exchangeFile(harness)
        try write(#"[{"name": "Other Sig", "text": "Different", "keyword": "sig"}]"#, to: file)
        try await harness.importAndConfirm([file])
        #expect(harness.snippet(named: "Other Sig")?.keyword == nil)

        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.page == nil)
        #expect(harness.toasts.last?.title == "No New Snippets to Import")
        #expect(harness.library.index.snippets.count == 2)
    }

    @Test func aDamagedFileImportsNothing() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let good = exchangeFile(harness, "good.json")
        let bad = exchangeFile(harness, "bad.json")
        try write(#"[{"name": "Good", "text": "Good text"}]"#, to: good)
        for damaged in ["{ not json", #"{"items": []}"#, "\"just a string\"", ""] {
            try write(damaged, to: bad)
            harness.fakes.fileDialogs.filesToChoose = [good, bad]
            try await harness.run(SnippetIDs.importCommand)
            #expect(harness.page == nil)
            #expect(harness.toasts.last?.title == "Could Not Import bad.json")
            #expect(harness.toasts.last?.message == "It is not a snippets file. Nothing was imported.")
            #expect(harness.library.index.snippets.map(\.name) == ["Greeting"])
        }
        // A folder is not a file.
        harness.fakes.fileDialogs.filesToChoose = [harness.fakes.storage.root]
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.toasts.last?.message == "The file could not be read. Nothing was imported.")
    }

    @Test func aFileOverTheLimitIsNotReadToTheEnd() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "snippets-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "big.json")
        try Data(repeating: 0x20, count: 2_000).write(to: file)
        #expect(throws: SnippetImportFile.Failure.tooLarge) { try SnippetImportFile.readBytes(file, limit: 1_000) }
        #expect(try SnippetImportFile.readBytes(file, limit: 2_000).count == 2_000)
        #expect(throws: SnippetImportFile.Failure.unreadable) { try SnippetImportFile.readBytes(folder) }
        #expect(throws: SnippetImportFile.Failure.unreadable) {
            try SnippetImportFile.readBytes(folder.appending(path: "missing.json"))
        }
    }

    @Test func importReadsTheFeaturesOwnFileToo() async throws {
        let source = try await FeatureHarness.loaded(all)
        let target = try await FeatureHarness.loaded([])
        try await target.importAndConfirm([source.file])
        #expect(target.library.index.snippets.map(\.name) == all.map(\.name))
        #expect(target.snippet(named: "Bug Template")?.isPinned == true)
    }

    @Test func importFromSeveralFiles() async throws {
        let harness = try await FeatureHarness.loaded([])
        let first = exchangeFile(harness, "first.json")
        let second = exchangeFile(harness, "second.json")
        try write(#"[{"name": "One", "text": "1", "keyword": "k1"}]"#, to: first)
        try write(#"{"snippets": [{"name": "Two", "text": "2", "keyword": "k1"}]}"#, to: second)
        try await harness.importAndConfirm([first, second])
        #expect(harness.library.index.snippets.map(\.name) == ["One", "Two"])
        #expect(harness.snippet(named: "Two")?.keyword == nil, "the keyword went to the first")
        let request = try #require(harness.fakes.fileDialogs.openRequests.first)
        #expect(request.allowsMultiple)
        #expect(request.allowedTypes == ["json", "alfredsnippets"])
    }

    @Test func cancellingTheDialogsDoesNothing() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let imported = try await harness.run(SnippetIDs.importCommand)
        let exported = try await harness.run(SnippetIDs.exportCommand)
        #expect(imported.kind == .keepOpen && exported.kind == .keepOpen)
        #expect(harness.toasts.isEmpty)
        #expect(harness.huds.isEmpty)
        #expect(!harness.isClosed)
    }

    @Test func exportingNothingSaysSo() async throws {
        let harness = try await FeatureHarness.loaded([])
        harness.fakes.fileDialogs.saveLocation = exchangeFile(harness)
        try await harness.run(SnippetIDs.exportCommand)
        #expect(harness.toasts.last?.title == "No Snippets to Export")
        #expect(harness.fakes.fileDialogs.saveRequests.isEmpty)
    }

    @Test func importWhileTheFileIsUnreadableRefusesBeforeTheDialog() async throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        try write("broken", to: harness.file)
        await harness.start()
        let file = exchangeFile(harness)
        try write(#"[{"name": "One", "text": "1"}]"#, to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        await #expect(
            throws: ActionFailure(
                "Snippets Cannot Be Saved Right Now",
                message: "The snippets file could not be read. Fix or remove it first.")
        ) {
            try await harness.run(SnippetIDs.importCommand)
        }
        #expect(harness.fakes.fileDialogs.openRequests.isEmpty, "nobody picks a file for nothing")
        #expect(try String(contentsOf: harness.file, encoding: .utf8) == "broken")
    }

    @Test func settingsButtonsImportExportAndShowTheFile() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try await harness.pressSettingsButton("Show Snippets File in Finder")
        #expect(harness.fakes.workspace.revealed == [harness.file])
        harness.fakes.fileDialogs.saveLocation = exchangeFile(harness)
        try await harness.pressSettingsButton("Export Snippets")
        #expect(FileManager.default.fileExists(atPath: exchangeFile(harness).path))

        // The settings window cannot show the page, so it asks one question with the counts.
        let file = exchangeFile(harness, "more.json")
        try write(
            #"[{"name": "Greeting", "text": "Hello there", "keyword": "hi"}, {"name": "New", "text": "n"}]"#, to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        harness.confirmationAnswer = false
        try await harness.pressSettingsButton("Import Snippets")
        #expect(harness.confirmations.last?.title == "Import 1 Snippet?")
        #expect(harness.confirmations.last?.message == "Skipped 1 snippet you already have.")
        #expect(harness.snippet(named: "New") == nil, "the answer was no")
        harness.confirmationAnswer = true
        try await harness.pressSettingsButton("Import Snippets")
        #expect(harness.snippet(named: "New") != nil)
        #expect(harness.toasts.last?.title == "Imported 1 Snippet")
    }

    @Test func importAndExportNeverRunFromALink() throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        #expect(try harness.command(SnippetIDs.importCommand).allowsDeepLinks == false)
        #expect(try harness.command(SnippetIDs.exportCommand).allowsDeepLinks == false)
        #expect(try harness.command(SnippetIDs.importCommand).showsInRoot)
        #expect(harness.issues.isEmpty)
    }

    @Test func keywordsTravelAsTheyAreTyped() async throws {
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.keywordPrefix] = ";"
        let source = try await FeatureHarness.loaded([Fixture.greeting], fakes: fakes)
        let file = exchangeFile(source)
        source.fakes.fileDialogs.saveLocation = file
        try await source.run(SnippetIDs.exportCommand)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        #expect(raw?.first?["keyword"] as? String == ";hi", "other apps have no prefix of their own")

        // With the same prefix, the keyword comes back as it was; with none, it keeps the ";".
        let samePrefix = FakeServices()
        samePrefix.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.keywordPrefix] = ";"
        let back = try await FeatureHarness.loaded([], fakes: samePrefix)
        try await back.importAndConfirm([file])
        #expect(back.snippet(named: "Greeting")?.keyword == "hi")
        let plain = try await FeatureHarness.loaded([])
        try await plain.importAndConfirm([file])
        #expect(plain.snippet(named: "Greeting")?.keyword == ";hi")
    }

    @Test func namesTextAndKeywordsFromAFileAreCleaned() async throws {
        let harness = try await FeatureHarness.loaded([])
        let file = exchangeFile(harness)
        let entries: [[String: Any]] = [
            [
                "name": "Two\nLines\u{202E}txt", "text": "keep\ttabs\nand lines\u{1B}[201~ but no escape\u{0}",
                "keyword": "esc",
            ],
            ["name": "Hidden Keyword", "text": "x", "keyword": "ab\u{202E}c"],
            ["name": String(repeating: "n", count: 257), "text": "long name"],
            ["name": "Long Text", "text": String(repeating: "t", count: SnippetValidation.maximumLength + 1)],
            ["name": "  Spaced   Out  ", "text": "y", "collection": "Group\nName"],
        ]
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        try await harness.importAndConfirm([file])

        let cleaned = try #require(harness.snippet(named: "Two Lines\u{FFFD}txt"))
        #expect(cleaned.text == "keep\ttabs\nand lines[201~ but no escape")
        #expect(cleaned.keyword == "esc")
        #expect(harness.snippet(named: "Hidden Keyword")?.keyword == nil, "nobody types a direction override")
        #expect(harness.snippet(named: "Spaced Out")?.collection == "Group Name")
        #expect(harness.library.index.snippets.count == 3)
        #expect(
            harness.toasts.last?.message
                == "Imported 1 snippet without its keyword. Skipped 2 entries that were not valid.")
    }

    /// One entry that was not valid reads as one.
    @Test func oneEntryThatWasNotValidReadsAsOne() {
        var summary = ImportSummary()
        summary.added = 2
        summary.notValid = 1
        #expect(Strings.importNotes(summary) == "Skipped 1 entry that was not valid.")
    }
}
