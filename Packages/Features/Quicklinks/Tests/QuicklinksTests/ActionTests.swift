import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Actions against the fake workspace", .timeLimit(.minutes(1)))
@MainActor
struct ActionTests {
    private let docsLink = "https://docs.example.com/guide"

    @Test func theListOffersEachActionInOrder() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Docs")
        #expect(
            quicklinks.harness.actions().map(\.id) == [
                "open", "open-with", "copy-link", "edit", "duplicate", "toggle", "delete", "create",
            ])
        try quicklinks.harness.select(title: "Sample Tracker")
        #expect(
            quicklinks.harness.actions().map(\.id) == [
                "open", "copy-link", "edit", "duplicate", "set-default", "toggle", "delete", "create",
            ])
        let titles = quicklinks.harness.actions().map(\.title)
        #expect(titles.first == "Open")
        #expect(titles.contains("Delete Quicklink") && titles.contains("Turn Off Quicklink"))
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func openOpensTheLinkAndCloses() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Docs")
        let outcome = try await quicklinks.harness.performPrimary()
        #expect(outcome.kind == .close(hud: nil))
        #expect(quicklinks.fakes.workspace.opened.map(\.absoluteString) == [docsLink])
        #expect(quicklinks.fakes.workspace.openedWith.isEmpty)
    }

    @Test func aQuicklinkWithAnAppOpensWithThatApp() async throws {
        var docs = Samples.docs
        docs.openWith = Samples.browserID
        let quicklinks = try await QuicklinksHarness(file: QuicklinkFile(quicklinks: [docs]))
        let row = try await quicklinks.catalogRow("Sample Docs")
        #expect(row.icon == .favicon(domain: "docs.example.com"), "the site's icon wins over the app's")
        try await quicklinks.harness.performRoot("open", on: row)
        let opened = try #require(quicklinks.fakes.workspace.openedWith.first)
        #expect(opened.bundleID == Samples.browserID)
        #expect(opened.urls.map(\.absoluteString) == [docsLink])
        #expect(quicklinks.fakes.workspace.opened.isEmpty)
    }

    @Test func openWithListsTheAppsAndOpensWithTheChosenOne() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.fakes.workspace.applications = [
            AppInfo(bundleID: Samples.browserID, name: "Example Browser"),
            AppInfo(bundleID: "com.example.reader", name: "Example Reader"),
        ]
        try await quicklinks.selectInList("Sample Docs")
        let apps = try await quicklinks.harness.submenu("open-with")
        #expect(apps.map(\.title) == ["Example Browser", "Example Reader"])
        try await quicklinks.harness.perform(apps[1], row: quicklinks.harness.selectedRow)
        let opened = try #require(quicklinks.fakes.workspace.openedWith.first)
        #expect(opened.bundleID == "com.example.reader")
        #expect(opened.urls.map(\.absoluteString) == [docsLink])
    }

    @Test func openOnAQuicklinkWithArgumentsAsksForThem() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Tracker")
        let outcome = try await quicklinks.harness.performPrimary()
        #expect(outcome.kind == .push)
        guard case .form(let form) = quicklinks.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.title == "Sample Tracker")
        #expect(form.submitTitle == Strings.openSubmit)
        #expect(form.fields.map(\.id) == ["argument.Issue", "openWith"])
        try quicklinks.harness.fill("argument.Issue", text: "KIT 7")
        try quicklinks.harness.fill("openWith", text: Samples.browserID)
        try await quicklinks.harness.submit()
        let opened = try #require(quicklinks.fakes.workspace.openedWith.first)
        #expect(opened.urls.map(\.absoluteString) == ["https://tracker.example.com/issues/KIT%207"])
        #expect(opened.bundleID == Samples.browserID)
        #expect(quicklinks.harness.isClosed)
    }

    @Test func theArgumentsFormOffersDefaultsAndOptions() async throws {
        let quicklinks = try await QuicklinksHarness()
        let translate = try #require(quicklinks.feature.entry(id: "googletranslate"))
        let form = quicklinks.feature.forms.arguments(for: translate)
        #expect(form.fields.map(\.id) == ["argument.Query", "argument.To", "openWith"])
        #expect(form.fields.filter(\.isRequired).map(\.id) == ["argument.Query"])
        #expect(form.initialValues.text("argument.To") == "en")
    }

    @Test func copyLinkCopiesTheLinkAsWritten() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Search")
        let outcome = try await quicklinks.harness.perform("copy-link")
        #expect(quicklinks.fakes.pasteboard.copiedTexts == ["https://search.example.org/find?q={query}"])
        #expect(outcome.kind == .close(hud: HUD(Strings.copiedLink)))
    }

    @Test func setAsDefaultChangesTheEngineEverywhere() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Search DuckDuckGo")
        try await quicklinks.harness.perform("set-default")
        try await quicklinks.harness.settle()
        #expect(quicklinks.harness.context.settings[QuicklinksSettings.defaultSearch] == "duckduckgo")
        #expect(quicklinks.feature.defaultEngine?.id == "duckduckgo")
        #expect(quicklinks.harness.toasts.last?.title == Strings.defaultEngineSet("Search DuckDuckGo"))
        #expect(quicklinks.harness.selectedRow?.accessories.contains(.tag(Strings.defaultTag)) == true)
        #expect(!quicklinks.harness.actions().map(\.id).contains("set-default"))
    }

    @Test func turnOffHidesAQuicklinkFromRootAndTurnOnBringsItBack() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Tracker")
        try await quicklinks.harness.perform("toggle")
        #expect(!quicklinks.commandIDs().contains("open.sample-tracker"))
        #expect(quicklinks.harness.selectedRow?.accessories.contains(.tag(Strings.offTag)) == true)
        #expect(quicklinks.harness.toasts.last?.title == Strings.turnedOff("Sample Tracker"))
        #expect(quicklinks.harness.actions().first { $0.id == "toggle" }?.title == Strings.turnOn)
        try await quicklinks.harness.setFilter("off")
        #expect(quicklinks.harness.rows.map(\.title) == ["Sample Tracker"])
        try await quicklinks.harness.perform("toggle")
        #expect(quicklinks.commandIDs().contains("open.sample-tracker"))
    }

    @Test func deleteAsksFirstThenForgetsTheRow() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let id = ItemID("quicklink", "sample-docs")
        quicklinks.fakes.usage.recordUse(of: id, snapshot: nil)
        try await quicklinks.selectInList("Sample Docs")

        quicklinks.harness.confirmationAnswer = false
        try await quicklinks.harness.perform("delete")
        let asked = try #require(quicklinks.harness.confirmations.last)
        #expect(asked.title == "Delete \"Sample Docs\"?")
        #expect(asked.message == Strings.deleteOwnMessage)
        #expect(asked.isDestructive)
        #expect(quicklinks.feature.entry(id: "sample-docs") != nil, "declining keeps it")

        quicklinks.harness.confirmationAnswer = true
        try await quicklinks.harness.perform("delete")
        #expect(quicklinks.feature.entry(id: "sample-docs") == nil)
        #expect(!quicklinks.harness.rows.contains { $0.title == "Sample Docs" })
        #expect(quicklinks.fakes.usage.useCount(of: id) == 0)
        #expect(quicklinks.harness.toasts.last?.title == Strings.deletedQuicklink)
        #expect(try await quicklinks.storedFile()?.quicklinks.contains { $0.id == "sample-docs" } == false)
    }

    @Test func deletingABuiltInSaysHowToGetItBack() async throws {
        let quicklinks = try await QuicklinksHarness()
        try await quicklinks.selectInList("Search Bing")
        try await quicklinks.harness.perform("delete")
        #expect(quicklinks.harness.confirmations.last?.message == Strings.deleteBuiltInMessage)
        #expect(try await quicklinks.storedFile()?.removedDefaults == ["bing"])
    }

    @Test func aRefusedOpenShowsAFailure() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.fakes.workspace.failsToOpen = true
        quicklinks.harness.throwsActionErrors = false
        try await quicklinks.harness.performRoot("open", on: try await quicklinks.catalogRow("Sample Docs"))
        #expect(quicklinks.harness.toasts.last?.title == Strings.couldNotOpen)
        #expect(quicklinks.harness.toasts.last?.message == docsLink)
    }

    @Test func aLinkThatRendersBadlyIsNotOpened() async throws {
        let fromClipboard = Quicklink(id: "clip", name: "Open Copied Link", link: "{clipboard}")
        let quicklinks = try await QuicklinksHarness(file: QuicklinkFile(quicklinks: [fromClipboard]))
        quicklinks.fakes.pasteboard.simulateCopy("javascript:alert(1)")
        let row = try await quicklinks.catalogRow("Open Copied Link")
        await #expect(throws: ActionFailure(Strings.linkNotValid("Open Copied Link"), message: Strings.linkNotWeb)) {
            try await quicklinks.harness.performRoot("open", on: row)
        }
        #expect(quicklinks.fakes.workspace.opened.isEmpty)

        quicklinks.fakes.pasteboard.simulateCopy("docs.example.com/guide")
        try await quicklinks.harness.performRoot("open", on: row)
        #expect(quicklinks.fakes.workspace.opened.map(\.absoluteString) == [docsLink])
    }

    @Test func aLinkThatReadsTheSelectionAsksForAccessibilityFirst() async throws {
        let lookUp = Quicklink(id: "look-up", name: "Look Up", link: "https://lookup.example.com/?q={selection}")
        let withNote = Quicklink(
            id: "look-up-note", name: "Look Up With Note",
            link: "https://lookup.example.com/?q={selection}&note={argument name=\"Note\"}")
        let file = QuicklinkFile(quicklinks: [lookUp, withNote], removedDefaults: DefaultSearches.all.map(\.id))
        let quicklinks = try await QuicklinksHarness(file: file)
        quicklinks.fakes.permissions.set(.accessibility, to: .denied)
        quicklinks.fakes.selection.selection = .text("picked words")
        #expect(try quicklinks.harness.command("open.look-up-note").requires == [.accessibility])

        let row = try await quicklinks.catalogRow("Look Up")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await quicklinks.harness.performRoot("open", on: row)
        }
        #expect(quicklinks.fakes.selection.reads == 0, "nothing is read before the grant")
        #expect(quicklinks.fakes.workspace.opened.isEmpty)

        quicklinks.fakes.permissions.set(.accessibility, to: .granted)
        try await quicklinks.harness.performRoot("open", on: row)
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == ["https://lookup.example.com/?q=picked%20words"])
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func aQuicklinkDeletedWhileItsActionsWereShownSaysSo() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.selectInList("Sample Docs")
        let edit = try #require(quicklinks.harness.actions().first { $0.id == "edit" })
        try await quicklinks.feature.remove(id: "sample-docs")
        await #expect(throws: ActionFailure(Strings.quicklinkGone)) {
            try await quicklinks.harness.perform(edit, row: nil)
        }
    }

    @Test func aTypedAddressCanBeOpenedOpenedWithOrCopied() async throws {
        let quicklinks = try await QuicklinksHarness()
        quicklinks.fakes.workspace.applications = [AppInfo(bundleID: Samples.browserID, name: "Example Browser")]
        let row = try #require(quicklinks.harness.instantAnswers(for: "docs.example.com").first?.rows.first)
        let actions = quicklinks.harness.rootActions(for: row)
        #expect(actions.map(\.id) == ["open", "open-with", "copy-link"])
        #expect(actions.first?.title == "Open")
        try await quicklinks.harness.performRoot("open", on: row)
        #expect(quicklinks.fakes.workspace.opened.map(\.absoluteString) == ["https://docs.example.com"])
        let apps = try await quicklinks.harness.submenu("open-with", in: actions, row: row, launch: .root)
        try await quicklinks.harness.perform(try #require(apps.first), row: row, launch: .root)
        #expect(quicklinks.fakes.workspace.openedWith.first?.bundleID == Samples.browserID)
        try await quicklinks.harness.performRoot("copy-link", on: row)
        #expect(quicklinks.fakes.pasteboard.copiedTexts == ["https://docs.example.com"])
        #expect(quicklinks.harness.issues.isEmpty)
    }
}
