import Foundation
import Kit
import KitHosting
import Testing

@testable import Root

/// Tab after a query that ends in a space. The engine matches the query without its last spaces,
/// so the completion must continue what the user typed, space included, or not be offered.
@Suite("Completion after a space", .timeLimit(.minutes(1)))
struct CompletionSpaceTests {
    @Test func aSpaceThatTheTitleDoesNotHaveThereGetsNoCompletion() async throws {
        let fixture = await RootFixture.ready(apps: ExampleApps(titles: ["Notes", "Text Editor", "Calendar"]))
        _ = fixture.root.begin()
        #expect(fixture.root.update(query: "note").completion?.text == "notes")
        #expect(fixture.root.update(query: "note ").completion == nil, "never \"note s\"")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aSpaceThatTheTitleHasThereCompletesTheNextWord() async throws {
        let fixture = await RootFixture.ready(apps: ExampleApps(titles: ["Notes", "Text Editor", "Calendar"]))
        _ = fixture.root.begin()
        let completion = try #require(fixture.root.update(query: "text ").completion)
        #expect(completion.text == "text Editor", "one space, as typed")
        #expect(completion.ghostText(after: "text ") == "Editor")
        #expect(fixture.root.update(query: "text").completion?.text == "text Editor")
        #expect(fixture.root.update(query: "calen").completion?.text == "calendar")
        fixture.root.end()
        await fixture.shutdown()
    }
}
