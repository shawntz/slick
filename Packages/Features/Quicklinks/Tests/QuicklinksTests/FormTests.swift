import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Forms and validation", .timeLimit(.minutes(1)))
@MainActor
struct FormTests {
    @Test func createSavesAQuicklinkAndAddsItToRootSearch() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("create")
        try quicklinks.harness.fill("name", text: "  Team Board  ")
        try quicklinks.harness.fill("link", text: "board.example.com/{query}")
        try quicklinks.harness.fill("keywords", .strings(["Board", " tb ", "board", ""]))
        try quicklinks.harness.fill("openWith", text: Samples.browserID)
        try quicklinks.harness.fill("icon", text: "star")
        try quicklinks.harness.fill("fallback", .bool(true))
        let outcome = try await quicklinks.harness.submit()
        #expect(outcome.kind == .pop)

        let saved = try #require(quicklinks.feature.entries.last?.quicklink)
        #expect(saved.name == "Team Board")
        #expect(saved.link == "https://board.example.com/{query}")
        #expect(saved.keywords == ["board", "tb"])
        #expect(saved.openWith == Samples.browserID)
        #expect(saved.icon == "star")
        #expect(saved.isFallback && saved.isEnabled && !saved.isBuiltIn)
        #expect(try await quicklinks.storedFile()?.quicklinks.last == saved)
        let command = try quicklinks.harness.command(saved.commandID)
        #expect(command.icon == .symbol("star"))
        #expect(command.fallback != nil)
        #expect(quicklinks.harness.toasts.last?.title == Strings.savedQuicklink)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func aStaticLinkJoinsTheCatalog() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("create")
        try quicklinks.harness.fill("name", text: "Status Page")
        try quicklinks.harness.fill("link", text: "https://status.example.com")
        try await quicklinks.harness.submit()
        #expect(try await quicklinks.harness.catalogRows().map(\.title).contains("Status Page"))
    }

    @Test func theEditorStartsWithTheExpectedFields() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("create", arguments: ["link": "https://new.example.com"])
        guard case .form(let form) = quicklinks.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.title == Strings.createQuicklink)
        #expect(form.submitTitle == Strings.saveQuicklink)
        #expect(form.fields.map(\.id) == ["name", "link", "keywords", "openWith", "icon", "fallback"])
        #expect(form.fields.filter(\.isRequired).map(\.id) == ["name", "link"])
        #expect(quicklinks.harness.page?.formValues.text("link") == "https://new.example.com")
        #expect(quicklinks.harness.page?.formValues.text("icon") == "")
    }

    @Test func requiredFieldsAreCheckedFirst() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("create")
        let errors = try await submitErrors(quicklinks)
        #expect(Set(errors.keys) == ["name", "link"])
    }

    @Test func mistakesAreReportedByField() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("create")
        let link = "https://x.example.com/{argument nme=\"a\"}"
        try quicklinks.harness.fill("name", text: String(repeating: "n", count: 101))
        try quicklinks.harness.fill("link", text: link)
        try quicklinks.harness.fill("keywords", .strings(["two words"]))
        let errors = try await submitErrors(quicklinks)
        #expect(errors["name"]?.message == Strings.nameTooLong)
        let placeholder = (link as NSString).range(of: "{argument nme=\"a\"}")
        #expect(errors["link"]?.range == placeholder.location..<placeholder.location + placeholder.length)
        #expect(errors["keywords"]?.message == Strings.keywordOneWord)
        #expect(quicklinks.feature.entries.count == 3, "nothing was saved")
    }

    @Test func aLongKeywordIsRefused() {
        let values = FormValues([
            "name": .text("A"), "link": .text("https://a.example.com"),
            "keywords": .strings([String(repeating: "k", count: 33)]),
        ])
        #expect(QuicklinkFormRules.errors(in: values)["keywords"]?.message == Strings.keywordTooLong)
    }

    @Test func editKeepsTheIDTheKeywordsAndTheBuiltInMark() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Search Wikipedia")
        try await quicklinks.harness.perform("edit")
        #expect(quicklinks.harness.page?.formValues.strings("keywords") == ["wiki", "wikipedia"])
        try quicklinks.harness.fill("name", text: "Search German Wikipedia")
        try quicklinks.harness.fill("link", text: "https://de.wikipedia.org/wiki/Special:Search?search={query}")
        try await quicklinks.harness.submit()
        let wiki = try #require(quicklinks.feature.entry(id: "wikipedia")?.quicklink)
        #expect(wiki.name == "Search German Wikipedia")
        #expect(wiki.isBuiltIn && wiki.isFallback)
        #expect(wiki.keywords == ["wiki", "wikipedia"])
        #expect(quicklinks.harness.rows.contains { $0.title == "Search German Wikipedia" }, "the list reloaded")
    }

    @Test func editQuicklinkFromRootPicksOneFirst() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("edit")
        try quicklinks.harness.select(title: "Sample Docs")
        #expect(quicklinks.harness.actions().first?.id == "edit", "Return edits on this page")
        try await quicklinks.harness.performPrimary()
        guard case .form(let form) = quicklinks.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.title == Strings.editQuicklink)
        #expect(quicklinks.harness.page?.formValues.text("name") == "Sample Docs")

        quicklinks.harness.pop()
        quicklinks.harness.pop()
        try await quicklinks.harness.run("edit", arguments: ["id": "sample-tracker"])
        #expect(quicklinks.harness.page?.formValues.text("name") == "Sample Tracker", "an ID skips the picker")
    }

    @Test func duplicateMakesANewQuicklinkOfTheUsersOwn() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Search Google")
        try await quicklinks.harness.perform("duplicate")
        guard case .form(let form) = quicklinks.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.title == Strings.duplicate)
        #expect(quicklinks.harness.page?.formValues.text("name") == "Search Google Copy")
        try await quicklinks.harness.submit()
        let copy = try #require(quicklinks.feature.entries.last?.quicklink)
        #expect(copy.name == "Search Google Copy")
        #expect(copy.id != "google" && !copy.isBuiltIn)
        #expect(quicklinks.feature.entry(id: "google")?.quicklink == DefaultSearches.quicklink(id: "google"))
    }

    @Test func aHandWrittenIconSurvivesTheEditor() async throws {
        var docs = Samples.docs
        docs.icon = "books.vertical"
        let quicklinks = try await QuicklinksHarness(file: QuicklinkFile(quicklinks: [docs]))
        let form = quicklinks.feature.forms.edit(docs)
        guard case .dropdown(let options, let initial) = try #require(form.fields.first { $0.id == "icon" }).kind else {
            Issue.record("expected a dropdown")
            return
        }
        #expect(options.last?.value == "books.vertical")
        #expect(initial == "books.vertical")
    }

    private func submitErrors(_ quicklinks: QuicklinksHarness) async throws -> [String: FieldError] {
        do {
            try await quicklinks.harness.submit()
        } catch HarnessError.invalidForm(let errors) {
            return errors
        }
        Issue.record("expected the form to be refused")
        return [:]
    }
}
