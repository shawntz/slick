import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Create Note", .timeLimit(.minutes(1)))
struct CreateTests {
    @Test func savingWritesAMarkdownFileNamedAfterTheTitleAndOffersToOpenIt() async throws {
        let harness = try await FeatureHarness.make()
        #expect(harness.issues.isEmpty)
        try await harness.run(NoteIDs.createCommand)
        try harness.fill("title", text: "Shopping List")
        try harness.fill("body", text: "Milk\n\n- eggs\n")
        try harness.fill("tags", .strings(["#errands", "home"]))
        try await harness.submit()

        #expect(try harness.names() == ["Shopping List.md"])
        #expect(try harness.text(of: "Shopping List.md") == "# Shopping List\n\nMilk\n\n- eggs\n\n#errands #home\n")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: harness.defaultFolder.appending(path: "Shopping List.md").path)
        #expect(attributes[.modificationDate] as? Date == harness.fakes.clock.now)
        #expect(harness.pages.isEmpty)
        #expect(harness.toasts.last?.title == "Created Note")
        #expect(harness.library.index.notes.map(\.title) == ["Shopping List"])

        // The toast's button opens the note on its own page.
        try await harness.performToastAction()
        guard case .markdown(let shown) = harness.detail?.body else {
            Issue.record("the note page shows no Markdown")
            return
        }
        #expect(shown.hasPrefix("# Shopping List\n"))
        #expect(harness.issues.isEmpty)
    }

    @Test func aSecondNoteWithTheSameTitleGetsANumber() async throws {
        let harness = try await FeatureHarness.make([("plans.md", "# plans\n")])
        for title in ["Plans", "PLANS"] {
            try await harness.run(NoteIDs.createCommand)
            try harness.fill("title", text: title)
            try await harness.submit()
        }
        #expect(try harness.names() == ["PLANS 3.md", "Plans 2.md", "plans.md"])
    }

    @Test func aTitleMadeOfAnythingGivesASafeFileName() async throws {
        let harness = try await FeatureHarness.make()
        try await harness.run(NoteIDs.createCommand)
        try harness.fill("title", text: "../Q3: plans/ideas\u{202E}\n...")
        try await harness.submit()
        #expect(try harness.names() == ["-Q3- plans-ideas.md"])
        // The row shows the title as written, on one line, with the override made visible.
        #expect(harness.library.index.notes.first?.title == "../Q3: plans/ideas\u{FFFD} ...")
    }

    @Test func aNoteWithoutATitleIsTitledByItsFirstLine() async throws {
        let harness = try await FeatureHarness.make()
        try await harness.run(NoteIDs.createCommand)
        try harness.fill("body", text: "Call the plumber\nabout the sink")
        try await harness.submit()
        #expect(try harness.names() == ["Call the plumber.md"])
        #expect(try harness.text(of: "Call the plumber.md") == "Call the plumber\nabout the sink\n")
        #expect(harness.library.index.notes.first?.title == "Call the plumber")
    }

    @Test func theFormRefusesNothingAndBadTags() async throws {
        let harness = try await FeatureHarness.make()
        try await harness.run(NoteIDs.createCommand)
        try harness.fill("title", text: " \u{200B} ")
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        #expect(harness.page?.formErrors["title"]?.message == Strings.needsText)

        try harness.fill("title", text: "Fine")
        try harness.fill("tags", .strings(["ok", "not ok!", "123"]))
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        #expect(harness.page?.formErrors["tags"]?.message == Strings.badTags)
        #expect(try harness.names().isEmpty)

        // Spaces in a tag become dashes, and repeats go.
        try harness.fill("tags", .strings(["road trip", "Road-Trip", "#2027-plans"]))
        try await harness.submit()
        #expect(try harness.text(of: "Fine.md") == "# Fine\n\n#road-trip #2027-plans\n")
    }

    @Test func everyCommandFromALinkOnlyOpensAPage() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        for command in harness.feature.commands {
            #expect(command.showsInRoot)
            #expect(command.confirmation == nil)
            let outcome = try await harness.run(
                command.id, arguments: [NoteIDs.textArgument: "from a page"], launch: .deeplink)
            #expect(outcome.kind == .push)
            harness.pop()
        }
        #expect(try harness.names() == ["Groceries.md"])
        #expect(try harness.text(of: "Groceries.md") == Sample.groceries)
        #expect(harness.fakes.pasteboard.pastes.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }
}
