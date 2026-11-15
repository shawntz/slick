import Foundation
import Kit
import KitTesting
import Testing

@testable import Snippets

@Suite("Forms and validation", .timeLimit(.minutes(1)))
struct FormTests {
    /// Opens Create Snippet, fills it and submits it, returning the errors if it was refused.
    private func create(
        _ harness: FeatureHarness<SnippetsFeature>, name: String = "New", text: String = "Text",
        keyword: String = "", collection: String = "", expands: Bool = true
    ) async throws -> [String: FieldError] {
        try await harness.run(SnippetIDs.createCommand)
        try harness.fill(FormFields.name, text: name)
        try harness.fill(FormFields.text, text: text)
        try harness.fill(FormFields.keyword, text: keyword)
        try harness.fill(FormFields.collection, text: collection)
        try harness.fill(FormFields.expands, .bool(expands))
        do {
            try await harness.submit()
            return [:]
        } catch HarnessError.invalidForm(let errors) {
            harness.pop()
            return errors
        }
    }

    @Test func createSavesTheSnippetAndGoesBack() async throws {
        let harness = try await FeatureHarness.loaded([])
        try await harness.openSearch()
        let errors = try await create(
            harness, name: "  Meeting Notes ", text: "Agenda:\n{cursor}", keyword: " mtg ", collection: " Work ")
        #expect(errors.isEmpty)
        #expect(harness.pages.count == 1, "back on the list")
        #expect(harness.rows.map(\.title) == ["Meeting Notes"])
        #expect(harness.toasts.last?.title == "Saved Meeting Notes")
        let saved = try #require(harness.snippet(named: "Meeting Notes"))
        #expect(saved.keyword == "mtg")
        #expect(saved.collection == "Work")
        #expect(saved.text == "Agenda:\n{cursor}")
        #expect(harness.issues.isEmpty)
    }

    @Test func theFormAsksForWhatItNeedsAndExplains() async throws {
        let harness = try await FeatureHarness.loaded([])
        try await harness.run(SnippetIDs.createCommand)
        guard case .form(let form) = harness.page?.page else {
            Issue.record("not a form")
            return
        }
        #expect(form.title == "Create Snippet")
        #expect(form.fields.map(\.id) == ["name", "text", "keyword", "collection", "expands"])
        #expect(form.fields.first { $0.id == "text" }?.info?.contains("{clipboard}") == true)
        if case .multiline(_, _, let highlights) = form.fields[1].kind {
            #expect(highlights)
        } else {
            Issue.record("the text field is not multiline")
        }
        await #expect(throws: HarnessError.invalidForm(["name": "Required", "text": "Required"])) {
            try await harness.submit()
        }
    }

    @Test func namesMustBeUnique() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let errors = try await create(harness, name: "Greeting")
        #expect(errors["name"]?.message.hasPrefix("Another snippet already has this name.") == true)
    }

    @Test func brokenPlaceholdersPointAtThemselves() async throws {
        let harness = try await FeatureHarness.loaded([])
        let text = #"Due {date offset="tomorrow"} ok"#
        let errors = try await create(harness, text: text)
        let error = try #require(errors["text"])
        #expect(error.message.hasPrefix("This placeholder has a problem: offset must look like"))
        #expect(error.range == 4..<28)
    }

    @Test func includedSnippetsMustExistAndNotBeItself() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let missing = try await create(harness, name: "Outer", text: #"A {snippet name="Nope"}"#)
        #expect(missing["text"] == FieldError(#"No snippet is called "Nope"."#, range: 2..<23))
        let itself = try await create(harness, name: "Outer", text: #"{snippet name="Outer"}"#)
        #expect(itself["text"]?.message == "A snippet cannot include itself.")
        #expect(try await create(harness, name: "Outer", text: #"{snippet name="Greeting"}!"#).isEmpty)
    }

    @Test func cursorOnlyOnce() async throws {
        let harness = try await FeatureHarness.loaded([])
        let errors = try await create(harness, text: "{cursor} and {cursor}")
        #expect(
            errors["text"]
                == FieldError("Use {cursor} only once. The insertion point goes to the first one.", range: 13..<21))
    }

    @Test func textHasALengthLimit() async throws {
        let harness = try await FeatureHarness.loaded([])
        let errors = try await create(harness, text: String(repeating: "a", count: SnippetValidation.maximumLength + 1))
        #expect(errors["text"]?.message == "A snippet can hold up to 65536 characters.")
    }

    @Test func keywordRules() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting, Fixture.signoff])
        #expect(
            try await create(harness, keyword: "two words")["keyword"]?.message
                == "A keyword cannot contain spaces or line breaks.")
        #expect(
            try await create(harness, keyword: "x")["keyword"]?.message.hasPrefix("Use at least two characters") == true
        )
        #expect(
            try await create(harness, keyword: "hi")["keyword"]?.message == "\"Greeting\" already uses this keyword.")
        // With immediate expansion, "sig" would always fire before "sign" was finished.
        let shadowed = try await create(harness, keyword: "sign")["keyword"]?.message
        #expect(shadowed?.hasPrefix("\"Sign Off\" expands as soon as you type \"sig\"") == true)
        let shadows = try await create(harness, keyword: "s")["keyword"]?.message
        #expect(shadows?.hasPrefix("Use at least two characters") == true)
        let prefixOfOther = try await create(harness, name: "Short", keyword: "si")["keyword"]?.message
        #expect(prefixOfOther?.hasPrefix("This keyword would expand before you could finish \"sig\"") == true)
        // A snippet that does not expand hides nothing.
        #expect(try await create(harness, name: "Quiet", keyword: "signal", expands: false).isEmpty)
    }

    @Test func keywordRulesFollowTheSettings() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.signoff])
        harness.context.settings[SnippetsSettings.keywordPrefix] = ";"
        #expect(try await create(harness, name: "One", keyword: "x").isEmpty, "\";x\" is two characters")
        harness.context.settings[SnippetsSettings.trigger] = .afterDelimiter
        #expect(try await create(harness, name: "Two", keyword: "sign").isEmpty, "a delimiter ends each keyword")
    }

    @Test func editChangesTheSnippetInPlace() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting, Fixture.address])
        try await harness.openSearch()
        try harness.select(title: "Greeting")
        try await harness.perform("edit")
        guard case .form(let form) = harness.page?.page else {
            Issue.record("not a form")
            return
        }
        #expect(form.title == "Edit Snippet")
        #expect(form.submitTitle == "Save Snippet")
        // Its own name and keyword do not count as taken.
        try await harness.submit()
        try await harness.perform("edit")
        try harness.fill(FormFields.name, text: "Hello")
        try harness.fill(FormFields.keyword, text: "addr")
        await #expect(throws: HarnessError.invalidForm(["keyword": "\"Office Address\" already uses this keyword."])) {
            try await harness.submit()
        }
        try harness.fill(FormFields.keyword, text: "hey")
        try await harness.submit()
        let edited = try #require(harness.library.index.snippet(id: Fixture.greeting.id))
        #expect(edited.name == "Hello")
        #expect(edited.keyword == "hey")
        #expect(harness.rows.map(\.title).contains("Hello"))
    }

    @Test func duplicateOpensAFilledFormWithAFreeName() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.signoff, Fixture.snippet("Sign Off Copy", "x")])
        try await harness.openSearch()
        try harness.select(title: "Sign Off")
        try await harness.perform("duplicate")
        #expect(harness.page?.formValues.text(FormFields.name) == "Sign Off Copy 2")
        #expect(harness.page?.formValues.text(FormFields.keyword) == "")
        #expect(harness.page?.formValues.text(FormFields.collection) == "Email")
        try await harness.submit()
        let copy = try #require(harness.snippet(named: "Sign Off Copy 2"))
        #expect(copy.text == Fixture.signoff.text)
        #expect(copy.id != Fixture.signoff.id)
    }

    @Test func editCommandOpensTheEditorForASnippetByID() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        #expect(try !harness.command(SnippetIDs.editCommand).showsInRoot)
        try await harness.run(SnippetIDs.editCommand, arguments: [SnippetIDs.snippetArgument: Fixture.greeting.id])
        #expect(harness.page?.formValues.text(FormFields.name) == "Greeting")
        await #expect(throws: ActionFailure("This Snippet No Longer Exists")) {
            try await harness.run(SnippetIDs.editCommand, arguments: [SnippetIDs.snippetArgument: "gone"])
        }
    }

    /// Clipboard history's Save as Snippet runs `cmd:snippets.create` with a `text` argument. It
    /// cannot import this feature, so these names are the contract.
    @Test func theCommandOtherFeaturesHandTextToKeepsItsName() {
        #expect(SnippetIDs.command(SnippetIDs.createCommand) == ItemID.command(feature: "snippets", command: "create"))
        #expect(SnippetIDs.textArgument == "text")
        #expect(SnippetIDs.nameArgument == "name")
    }

    @Test func createTakesTextFromOtherFeatures() async throws {
        let harness = try await FeatureHarness.loaded([])
        try await harness.run(
            SnippetIDs.createCommand,
            arguments: [SnippetIDs.textArgument: "Handed over", SnippetIDs.nameArgument: "Handed"])
        #expect(harness.page?.formValues.text(FormFields.text) == "Handed over")
        #expect(harness.page?.formValues.text(FormFields.name) == "Handed")
    }
}
