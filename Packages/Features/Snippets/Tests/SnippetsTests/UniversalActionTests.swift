import Foundation
import Kit
import KitTesting
import Testing

@testable import Snippets

@Suite("Save as Snippet", .timeLimit(.minutes(1)))
struct UniversalActionTests {
    @Test func selectedTextOpensAFilledFormAndSaves() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let selection = Selection.text("Please find the report attached.\nThanks")
        #expect(harness.universalActions(for: selection).map(\.title) == ["Save as Snippet"])
        try await harness.performUniversal("save-as-snippet", on: selection)
        #expect(harness.page?.formValues.text(FormFields.text) == "Please find the report attached.\nThanks")
        #expect(harness.page?.formValues.text(FormFields.name) == "Please find the report attached.")
        try harness.fill(FormFields.keyword, text: "rpt")
        try await harness.submit()
        let saved = try #require(harness.snippet(named: "Please find the report attached."))
        #expect(saved.text == "Please find the report attached.\nThanks")
        #expect(saved.keyword == "rpt")
        #expect(harness.issues.isEmpty)
        #expect(harness.fakes.selection.reads == 0, "the host hands the selection over")
    }

    @Test func theSuggestedNameIsShortAndFree() async throws {
        let index = LibraryIndex([Fixture.snippet("Greeting", "x")])
        #expect(SnippetForms.suggestedName(for: "Greeting", in: index) == "Greeting 2")
        let long = "one two three four five six seven eight nine ten eleven twelve"
        #expect(SnippetForms.suggestedName(for: long, in: index) == "one two three four five six seven eight")
        #expect(SnippetForms.suggestedName(for: String(repeating: "x", count: 60), in: index).count == 40)
        #expect(SnippetForms.suggestedName(for: "\n  \n", in: index) == "New Snippet")
    }

    @Test func offeredOnlyForText() async throws {
        let harness = try await FeatureHarness.loaded([])
        #expect(harness.universalActions(for: .url(URL(string: "https://example.com")!)).isEmpty)
        #expect(harness.universalActions(for: .files([URL(filePath: "/tmp/example.txt")])).isEmpty)
    }

    @Test func textWithBrokenPlaceholdersIsExplainedBeforeSaving() async throws {
        let harness = try await FeatureHarness.loaded([])
        try await harness.performUniversal("save-as-snippet", on: .text(#"Due {date offset="later"}"#))
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        #expect(harness.page?.formErrors["text"]?.range == 4..<25)
    }
}
