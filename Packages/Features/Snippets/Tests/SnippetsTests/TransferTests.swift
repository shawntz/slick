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

        // The file has the shape other launchers read: name, text and keyword.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        #expect(raw?.first?["name"] as? String == "Greeting")
        #expect(raw?.first?["keyword"] as? String == "hi")
        #expect(raw?.first?["id"] == nil, "IDs stay local")

        let target = try await FeatureHarness.loaded([])
        target.fakes.fileDialogs.filesToChoose = [file]
        try await target.run(SnippetIDs.importCommand)
        #expect(target.toasts.last?.title == "Imported 5 Snippets")
        #expect(target.toasts.last?.message == nil)
        func fields(_ snippets: [Snippet]) -> [String] {
            snippets.map {
                "\($0.name)|\($0.text)|\($0.keyword ?? "-")|\($0.collection ?? "-")|\($0.expands)|\($0.isPinned)"
            }
        }
        #expect(fields(target.library.index.snippets) == fields(source.library.index.snippets))
        #expect(target.library.index.snippets.allSatisfy { $0.created == target.fakes.clock.now })

        // Importing the same file again adds nothing.
        try await target.run(SnippetIDs.importCommand)
        #expect(target.toasts.last?.title == "No New Snippets to Import")
        #expect(target.toasts.last?.message == "Skipped 5 snippets you already have.")
        #expect(target.library.index.snippets.count == 5)
    }

    @Test func importNeverChangesWhatTheUserHas() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting, Fixture.signoff])
        let file = exchangeFile(harness)
        try write(
            """
            [
              {"name": "Greeting", "text": "Hello there", "keyword": "hi"},
              {"name": "Other Sig", "text": "Different", "keyword": "sig"},
              {"name": "Greeting", "text": "A different greeting"},
              {"name": "No Text"},
              {"text": "No name"},
              {"name": "Blank", "text": "   "},
              42,
              "loose string",
              {"name": "Fresh", "text": "Fresh text", "keyword": 7, "collection": "Imported"}
            ]
            """, to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.run(SnippetIDs.importCommand)

        #expect(harness.toasts.last?.title == "Imported 2 Snippets")
        #expect(
            harness.toasts.last?.message
                == "Skipped 1 snippet you already have. Skipped 1 snippet whose keyword another snippet uses. "
                + "Skipped 5 entries without a name or text. Renamed 1 snippet whose name was taken.")
        #expect(harness.snippet(named: "Sign Off")?.text == Fixture.signoff.text)
        #expect(harness.snippet(named: "Greeting")?.text == "Hello there")
        #expect(harness.snippet(named: "Greeting 2")?.text == "A different greeting")
        let fresh = try #require(harness.snippet(named: "Fresh"))
        #expect(fresh.keyword == nil, "a keyword of the wrong type is dropped")
        #expect(fresh.collection == "Imported")
        #expect(try await harness.storedSnippets().count == 4)
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
            #expect(harness.toasts.last?.title == "Could Not Import bad.json")
            #expect(harness.toasts.last?.message == "It is not a snippets file. Nothing was imported.")
            #expect(harness.library.index.snippets.map(\.name) == ["Greeting"])
        }
    }

    @Test func importReadsTheFeaturesOwnFileToo() async throws {
        let source = try await FeatureHarness.loaded(all)
        let target = try await FeatureHarness.loaded([])
        target.fakes.fileDialogs.filesToChoose = [source.file]
        try await target.run(SnippetIDs.importCommand)
        #expect(target.library.index.snippets.map(\.name) == all.map(\.name))
        #expect(target.snippet(named: "Bug Template")?.isPinned == true)
    }

    @Test func importFromSeveralFiles() async throws {
        let harness = try await FeatureHarness.loaded([])
        let first = exchangeFile(harness, "first.json")
        let second = exchangeFile(harness, "second.json")
        try write(#"[{"name": "One", "text": "1", "keyword": "k1"}]"#, to: first)
        try write(#"{"snippets": [{"name": "Two", "text": "2", "keyword": "k1"}]}"#, to: second)
        harness.fakes.fileDialogs.filesToChoose = [first, second]
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.library.index.snippets.map(\.name) == ["One"])
        #expect(harness.toasts.last?.message == "Skipped 1 snippet whose keyword another snippet uses.")
        let request = try #require(harness.fakes.fileDialogs.openRequests.first)
        #expect(request.allowsMultiple)
        #expect(request.allowedTypes == ["json"])
    }

    @Test func cancellingTheDialogsDoesNothing() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try await harness.run(SnippetIDs.importCommand)
        try await harness.run(SnippetIDs.exportCommand)
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

    @Test func importWhileTheFileIsUnreadableRefuses() async throws {
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
        #expect(try String(contentsOf: harness.file, encoding: .utf8) == "broken")
    }

    @Test func settingsButtonsImportExportAndShowTheFile() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try await harness.pressSettingsButton("Show Snippets File in Finder")
        #expect(harness.fakes.workspace.revealed == [harness.file])
        harness.fakes.fileDialogs.saveLocation = exchangeFile(harness)
        try await harness.pressSettingsButton("Export Snippets")
        #expect(FileManager.default.fileExists(atPath: exchangeFile(harness).path))
    }
}
