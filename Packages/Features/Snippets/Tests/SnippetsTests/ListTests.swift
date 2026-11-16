import Foundation
import Kit
import KitTemplates
import KitTesting
import Testing

@testable import Snippets

@Suite("Search Snippets and root search", .timeLimit(.minutes(1)))
struct ListTests {
    private let all = [Fixture.greeting, Fixture.signoff, Fixture.address, Fixture.bug]

    @Test func sectionsGroupPinnedLooseAndCollections() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        #expect(harness.issues.isEmpty)
        #expect(harness.sections.map(\.title) == ["Pinned", "Snippets", "Email"])
        #expect(harness.rows.map(\.title) == ["Bug Template", "Greeting", "Office Address", "Sign Off"])
        let greeting = try #require(harness.rows.first { $0.title == "Greeting" })
        #expect(greeting.subtitle == "Hello there")
        #expect(greeting.accessories == [.tag("hi")])
        #expect(greeting.id == ItemID("snippet", Fixture.greeting.id))
        #expect(greeting.memory == .learnOnly)
        #expect(harness.page?.dropdown?.options.map(\.id) == ["all", "collection:Email", "collection:Work"])
        guard case .list(let page) = harness.page?.page else {
            Issue.record("not a list")
            return
        }
        #expect(page.showsDetail)
    }

    @Test func theCollectionFilterNarrowsTheList() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        try await harness.setFilter("collection:Email")
        #expect(harness.sections.map(\.title) == ["Email"])
        #expect(harness.rows.map(\.title) == ["Office Address", "Sign Off"])
        try await harness.setFilter("collection:Work")
        #expect(harness.sections.map(\.title) == ["Pinned"])
        try await harness.setFilter("all")
        #expect(harness.rows.count == 4)
    }

    @Test func searchMatchesNamesKeywordsAndText() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        try await harness.setQuery("sign")
        #expect(harness.rows.first?.title == "Sign Off")
        try await harness.setQuery("sample town")
        #expect(harness.rows.map(\.title) == ["Office Address"])
        try await harness.setQuery("addr")
        #expect(harness.rows.map(\.title) == ["Office Address"])
        #expect(harness.fakes.fuzzyIndex.builtIndexSizes == [4], "the list is indexed once, not per keystroke")
    }

    @Test func keywordsShowWithThePrefix() async throws {
        let harness = try await FeatureHarness.loaded(all)
        harness.context.settings[SnippetsSettings.keywordPrefix] = ";"
        try await harness.openSearch()
        #expect(harness.rows.first { $0.title == "Greeting" }?.accessories == [.tag(";hi")])
    }

    @Test func theDetailMarksPlaceholders() async throws {
        let wrapper = Fixture.snippet("Wrapper", #"{snippet name="Sign Off"} and {clipboard}"#)
        let harness = try await FeatureHarness.loaded(all + [wrapper])
        try await harness.openSearch()
        try harness.select(title: "Sign Off")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == .markdown("Best,\\\n`{cursor}`\\\nThe Team"))
        #expect(
            detail.metadata == [
                .label("Keyword", value: "sig"),
                .label("Expansion", value: "When the keyword is typed"),
                .label("Collection", value: "Email", icon: .symbol("folder")),
                .tags("Placeholders", [Tag("cursor", color: .purple)]),
                .label("Included by", value: "Wrapper"),
                .separator,
                .label("Used", value: "Never"),
            ])
    }

    @Test func markdownEscapesWhatWouldBeMarkup() {
        let template = Template("# Title *bold* 1. x\n- item\n2) y {date}\n\n`code` {clipboard | trim}")
        #expect(
            SnippetDetail.marked(template)
                == "\\# Title \\*bold\\* 1. x\\\n\\- item\\\n2\\) y `{date}`\\\n\\\n\\`code\\` `{clipboard | trim}`")
    }

    /// Each line ends in a hard break, so the pane keeps the snippet's lines without paragraph
    /// spacing. An empty line holds only the break, and a backslash the text ends a line with stays
    /// literal.
    @Test func linesJoinWithHardBreaks() {
        #expect(SnippetDetail.marked(Template("one\ntwo")) == "one\\\ntwo")
        #expect(SnippetDetail.marked(Template("one\n\n  \nfour")) == "one\\\n\\\n\\\nfour")
        #expect(SnippetDetail.marked(Template("\n\nmiddle\n\n")) == "middle", "no break at either end")
        #expect(SnippetDetail.marked(Template("path\\\nnext")) == "path\\\\\\\nnext")
    }

    @Test func aBrokenPlaceholderShowsAsAProblem() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.snippet("Broken", #"{date format="x" locale="y"}"#)])
        try await harness.openSearch()
        let detail = try #require(try await harness.loadDetail())
        #expect(
            detail.metadata.contains(
                .label(
                    "Problem", value: "format and locale cannot be used together",
                    icon: .symbol("exclamationmark.triangle", tint: .orange))))
    }

    @Test func actionsPasteFirstAndCopySecond() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        #expect(
            try harness.actionIDs(of: "Sign Off") == [
                "paste", "copy", "large-type", "edit", "duplicate", "pin", "create", "delete",
            ])
        #expect(harness.actions().primary?.title == "Paste Snippet")
        #expect(harness.actions().secondary?.title == "Copy to Clipboard")
        #expect(harness.actions().first { $0.id == "delete" }?.style == .destructive)
        #expect(harness.issues.isEmpty)
    }

    /// Show in Large Type, Command-L, on a snippet that asks for nothing: the text as it renders
    /// when the action runs. A snippet that asks for arguments leaves it out, because its text
    /// needs a form first.
    @Test func aSnippetShowsInLargeType() async throws {
        let letter = Fixture.snippet("Letter", #"Dear {argument name="name"}, {cursor}!"#)
        let harness = try await FeatureHarness.loaded(all + [letter])
        try await harness.openSearch()
        #expect(try harness.actionIDs(of: "Sign Off").prefix(3) == ["paste", "copy", "large-type"])
        let action = try #require(harness.actions().first { $0.id == "large-type" })
        #expect(action.title == "Show in Large Type" && action.shortcut == .largeType)
        try await harness.perform("large-type")
        #expect(harness.largeTypeTexts == ["Best,\n\nThe Team"])
        #expect(try !harness.actionIDs(of: "Letter").contains("large-type"))
        #expect(harness.issues.isEmpty)
    }

    @Test func pastePlacesTheCursorAndRecordsTheUse() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        try harness.select(title: "Sign Off")
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.pastes.map(\.content) == [.text("Best,\n\nThe Team")])
        #expect(harness.fakes.pasteboard.pastes.map(\.charactersAfterCursor) == [9])
        #expect(harness.isClosed)
        #expect(harness.fakes.usage.useCount(of: SnippetIDs.row(Fixture.signoff.id)) == 1)
    }

    @Test func pasteNeedsAccessibilityAndAsksOnlyThroughTheHost() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = try await FeatureHarness.loaded(all, fakes: fakes)
        try await harness.openSearch()
        try harness.select(title: "Greeting")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) { try await harness.performPrimary() }
        #expect(fakes.permissions.requests.isEmpty)
        #expect(fakes.pasteboard.pastes.isEmpty)
    }

    @Test func copyRendersAndCloses() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        try harness.select(title: "Sign Off")
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.copiedTexts == ["Best,\n\nThe Team"])
        #expect(harness.huds == ["Copied to Clipboard"])
    }

    @Test func aSnippetWithArgumentsAsksForThemFirst() async throws {
        let letter = Fixture.snippet(
            "Letter", #"Dear {argument name="name"}, {argument name="tone" options="thanks, sorry"} {cursor}!"#)
        let harness = try await FeatureHarness.loaded([letter])
        try await harness.openSearch()
        try await harness.performPrimary()
        guard case .form(let form) = harness.page?.page else {
            Issue.record("no form")
            return
        }
        #expect(form.title == "Letter")
        #expect(form.submitTitle == "Paste Snippet")
        #expect(form.requires == [.accessibility])
        #expect(form.fields.map(\.id).dropFirst() == ["name", "tone"])
        #expect(harness.page?.formValues.text("tone") == "thanks")
        await #expect(throws: HarnessError.invalidForm(["name": "Required"])) { try await harness.submit() }
        try harness.fill("name", text: "Sam")
        try harness.fill("tone", text: "sorry")
        try await harness.submit()
        #expect(harness.fakes.pasteboard.pastes.map(\.content) == [.text("Dear Sam, sorry !")])
        #expect(harness.fakes.pasteboard.pastes.first?.charactersAfterCursor == 1)
        #expect(harness.isClosed)
        #expect(harness.issues.isEmpty)
    }

    @Test func copyWithArgumentsUsesTheSameForm() async throws {
        let letter = Fixture.snippet("Letter", #"Hi {argument default="there"}"#)
        let harness = try await FeatureHarness.loaded([letter])
        try await harness.openSearch()
        try await harness.performSecondary()
        guard case .form(let form) = harness.page?.page else {
            Issue.record("no form")
            return
        }
        #expect(form.submitTitle == "Copy Snippet")
        #expect(form.fields.last?.title == "Argument 1")
        try await harness.submit()
        #expect(harness.fakes.pasteboard.copiedTexts == ["Hi there"])
        #expect(harness.huds == ["Copied to Clipboard"])
    }

    @Test func pinMovesASnippetToPinned() async throws {
        let harness = try await FeatureHarness.loaded(all)
        try await harness.openSearch()
        try harness.select(title: "Greeting")
        try await harness.perform("pin")
        #expect(harness.toasts.last?.title == "Pinned Greeting")
        #expect(harness.sections.first?.rows.map(\.title) == ["Bug Template", "Greeting"])
        try harness.select(title: "Greeting")
        #expect(harness.actions().first { $0.id == "pin" }?.title == "Unpin Snippet")
    }

    @Test func deleteAsksFirstAndForgetsTheSnippet() async throws {
        let wrapper = Fixture.snippet("Wrapper", #"{snippet name="Greeting"}!"#)
        let harness = try await FeatureHarness.loaded(all + [wrapper])
        let id = SnippetIDs.row(Fixture.greeting.id)
        harness.fakes.usage.recordUse(of: id)
        try await harness.openSearch()
        try harness.select(title: "Greeting")
        harness.confirmationAnswer = false
        try await harness.perform("delete")
        #expect(harness.snippet(named: "Greeting") != nil)
        let question = try #require(harness.confirmations.last)
        #expect(question.title == "Delete \"Greeting\"?")
        #expect(
            question.message == "You cannot undo this. \"Wrapper\" includes it, and will insert nothing in its place.")
        #expect(question.isDestructive)

        harness.confirmationAnswer = true
        try await harness.perform("delete")
        #expect(harness.snippet(named: "Greeting") == nil)
        #expect(!harness.rows.map(\.title).contains("Greeting"))
        #expect(harness.fakes.usage.useCount(of: id) == 0)
        #expect(try await harness.storedSnippets().count == 4)
    }

    @Test func emptyListOffersCreateAndImport() async throws {
        let harness = try await FeatureHarness.loaded([])
        try await harness.openSearch()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Snippets")
        #expect(harness.actions().map(\.title) == ["Create Snippet", "Import Snippets"])
        try await harness.perform("Create Snippet")
        #expect(harness.commandRuns.map(\.id) == [SnippetIDs.command("create")])
        #expect(harness.issues.isEmpty)
    }

    @Test func mostUsedOrderFollowsTheSetting() async throws {
        let harness = try await FeatureHarness.loaded(all)
        for _ in 0..<3 { harness.fakes.usage.recordUse(of: SnippetIDs.row(Fixture.signoff.id)) }
        try await harness.openSearch()
        #expect(harness.sections.last?.rows.map(\.title) == ["Office Address", "Sign Off"])
        harness.context.settings[SnippetsSettings.order] = .frequency
        try await harness.settle()
        #expect(harness.sections.last?.rows.map(\.title) == ["Sign Off", "Office Address"])
    }

    @Test func rootSearchFindsSnippetsByNameAndKeyword() async throws {
        let harness = try await FeatureHarness.loaded(all)
        #expect(
            try await harness.catalogRows().map(\.title) == ["Greeting", "Sign Off", "Office Address", "Bug Template"])

        let answer = try #require(harness.instantAnswers(for: "sig").first)
        #expect(answer.claimsTop)
        #expect(answer.rows.map(\.title) == ["Sign Off"])
        #expect(harness.instantAnswers(for: "si").isEmpty)
        #expect(harness.instantAnswers(for: "zebra").isEmpty)
        #expect(harness.instantAnswers(for: "").isEmpty)

        harness.context.settings[SnippetsSettings.keywordPrefix] = ";"
        #expect(harness.instantAnswers(for: "sig").isEmpty)
        #expect(harness.instantAnswers(for: ";sig").first?.rows.first?.accessories == [.tag(";sig")])

        harness.context.settings[SnippetsSettings.showsInRootSearch] = false
        #expect(try await harness.catalogRows().isEmpty)
        #expect(harness.instantAnswers(for: ";sig").isEmpty)
    }

    @Test func aRememberedRowStillHasItsActionsAfterARelaunch() async throws {
        let harness = try await FeatureHarness.loaded(all)
        let row = try #require(try await harness.catalogRows().first { $0.title == "Sign Off" })
        let snapshot = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(row))
        #expect(harness.rootActions(for: snapshot).map(\.id).first == "paste")
        try await harness.performRoot("copy", on: snapshot)
        #expect(harness.fakes.pasteboard.copiedTexts == ["Best,\n\nThe Team"])
        // A row for a snippet that is gone has no actions.
        let gone = Row(id: ItemID("snippet", "gone"), title: "Gone")
        #expect(harness.rootActions(for: gone).isEmpty)
    }

    @Test func rootRowsFollowTheLibrary() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let signal = try #require(harness.feature.catalogSources.first?.changes)
        let generation = signal.generation
        try await harness.library.add(SnippetDraft(name: "Later", text: "Later"))
        #expect(signal.generation == generation + 1)
        #expect(try await harness.catalogRows().count == 2)
    }
}
