import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Quick capture and Append to Note", .timeLimit(.minutes(1)))
struct CaptureTests {
    @Test func noteAndTextShowsCreateNoteAtTheTop() async throws {
        let harness = try await FeatureHarness.make()
        let answers = harness.instantAnswers(for: "note buy oat milk")
        let answer = try #require(answers.first)
        #expect(answers.count == 1)
        #expect(answer.claimsTop)
        #expect(answer.rows.map(\.title) == ["Create Note “buy oat milk”"])
        #expect(answer.rows.first?.memory == .never)
        #expect(harness.instantAnswers(for: "NOTE Buy").first?.rows.first?.title == "Create Note “Buy”")

        harness.context.settings[NotesSettings.quickCapture] = false
        #expect(harness.instantAnswers(for: "note buy oat milk").isEmpty)
        harness.context.settings[NotesSettings.quickCapture] = true

        for query in [
            "", "n", "note", "note ", "note     ", "note \u{200B}", "notes app", "nothing here", "knote x", "note\tx",
            "Notebook", "日本語",
        ] {
            #expect(harness.instantAnswers(for: query).isEmpty, "\(query)")
        }
    }

    @Test func returnSavesTheTextAndSaysSoInAHUD() async throws {
        let harness = try await FeatureHarness.make()
        let row = try #require(harness.instantAnswers(for: "note buy oat milk").first?.rows.first)
        #expect(harness.rootActions(for: row).map(\.id) == ["save", "edit", "append"])
        try await harness.performRoot("save", on: row, query: "note buy oat milk")
        #expect(harness.huds == [HUD.success("Saved Note")])
        #expect(try harness.names() == ["buy oat milk.md"])
        #expect(try harness.text(of: "buy oat milk.md") == "buy oat milk\n")
    }

    @Test func commandReturnOpensCreateNoteWithTheText() async throws {
        let harness = try await FeatureHarness.make()
        let row = try #require(harness.instantAnswers(for: "note call the plumber").first?.rows.first)
        let actions = harness.rootActions(for: row)
        #expect(actions.secondary?.id == "edit")
        try await harness.performRoot("edit", on: row)
        #expect(harness.page?.formValues.text("body") == "call the plumber")
        try harness.fill("title", text: "Plumber")
        try await harness.submit()
        #expect(try harness.text(of: "Plumber.md") == "# Plumber\n\ncall the plumber\n")
    }

    @Test func aPastedParagraphIsCutForTheTitleAndTheNote() async throws {
        let harness = try await FeatureHarness.make()
        let long = "note " + String(repeating: "word ", count: 50_000) + "end"
        let row = try #require(harness.instantAnswers(for: long).first?.rows.first)
        #expect(row.title.count <= "Create Note “”".count + QuickCapture.titleLength)
        #expect(row.title.hasSuffix("…”"))
        #expect((row.payload?.string?.utf8.count ?? 0) <= QuickCapture.maximumBytes)
        let multiline = try #require(harness.instantAnswers(for: "note first\nsecond").first?.rows.first)
        #expect(multiline.title == "Create Note “first second”")
    }

    @Test func appendToNoteAddsTheTypedTextToThePickedNote() async throws {
        let harness = try await FeatureHarness.make([
            ("Groceries.md", Sample.groceries), ("Budget 2027.md", Sample.budget),
        ])
        try await harness.run(NoteIDs.appendCommand, arguments: [NoteIDs.textArgument: "- bread"])
        #expect(harness.rows.map(\.title) == ["Groceries", "Budget 2027"])
        try await harness.setQuery("groc")
        #expect(harness.rows.map(\.title) == ["Groceries"])
        try await harness.performPrimary()
        #expect(harness.huds == [HUD.success("Appended to “Groceries”")])
        #expect(try harness.text(of: "Groceries.md") == "# Groceries\n\nMilk and eggs\n\n- bread\n\n#errands\n")
        #expect(harness.issues.isEmpty)
    }

    @Test func appendWithNoTextAsksForIt() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try await harness.run(NoteIDs.appendCommand)
        try await harness.performPrimary()
        #expect(harness.page.map { if case .form = $0.page { true } else { false } } == true)
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        try harness.fill("text", text: "Remember the coffee")
        try await harness.submit()
        #expect(harness.huds == [HUD.success("Appended to “Groceries”")])
        #expect(try harness.text(of: "Groceries.md").contains("Milk and eggs\n\nRemember the coffee\n\n#errands\n"))
    }

    @Test func quickCaptureCanAppendInstead() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        let row = try #require(harness.instantAnswers(for: "note pick up stamps").first?.rows.first)
        try await harness.performRoot("append", on: row)
        try harness.select(title: "Groceries")
        try await harness.performPrimary()
        #expect(try harness.text(of: "Groceries.md").contains("pick up stamps"))
        #expect(try harness.names() == ["Groceries.md"])
    }

    @Test func appendKeepsAChangeMadeElsewhere() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        // The file changes on disk after the last scan; append reads it again and keeps it.
        try harness.write("Groceries.md", "# Groceries\n\nTheir line\n", modified: harness.fakes.clock.now)
        let name = try await harness.library.append("Mine", to: "Groceries.md")
        #expect(name == "Groceries.md")
        #expect(try harness.text(of: "Groceries.md") == "# Groceries\n\nTheir line\n\nMine\n")
        await #expect(throws: Strings.nothingToAppend) { try await harness.library.append(" \n", to: "Groceries.md") }
    }
}
