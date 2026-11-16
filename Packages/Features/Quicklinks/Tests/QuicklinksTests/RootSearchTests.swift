import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Root search: catalog, commands and fallbacks", .timeLimit(.minutes(1)))
@MainActor
struct RootSearchTests {
    @Test func quicklinksWithoutArgumentsJoinTheCatalog() async throws {
        var file = Samples.file
        file.quicklinks.append(
            Quicklink(id: "off", name: "Turned Off", link: "https://off.example.com", isEnabled: false))
        let quicklinks = try await QuicklinksHarness(file: file)
        let rows = try await quicklinks.harness.catalogRows()
        #expect(rows.map(\.title) == ["Sample Docs"])
        let row = try #require(rows.first)
        #expect(row.id.rawValue == "quicklink:sample-docs")
        #expect(row.icon == .favicon(domain: "docs.example.com"))
        #expect(row.subtitle == "docs.example.com/guide")
        #expect(row.keywords.contains("docs.example.com"))
        #expect(row.memory == .learnOnly)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func quicklinksWithArgumentsAreCommandsWithFieldsInTheSearchBar() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let tracker = try quicklinks.harness.command("open.sample-tracker")
        #expect(tracker.title == "Sample Tracker")
        #expect(tracker.arguments.map(\.name) == ["Issue"])
        #expect(tracker.arguments.first?.placeholder == "Issue")
        #expect(tracker.keywords == ["issue"])
        #expect(tracker.subtitle == "tracker.example.com")
        #expect(tracker.fallback == nil, "not marked as a fallback")
        let google = try quicklinks.harness.command("open.google")
        #expect(google.arguments.map(\.name) == ["Query"])
        #expect(google.icon == .favicon(domain: "www.google.com"))
        #expect(!quicklinks.commandIDs().contains("open.sample-docs"))

        try await quicklinks.harness.run("open.sample-tracker", arguments: ["Issue": "KIT-42"])
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == ["https://tracker.example.com/issues/KIT-42"])
        #expect(quicklinks.harness.isClosed)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func managementCommandsUseTitleCase() async throws {
        let quicklinks = try await QuicklinksHarness()
        let titles = quicklinks.feature.commands.prefix(5).map(\.title)
        #expect(
            titles == [
                "Search Quicklinks", "Create Quicklink", "Edit Quicklink", "Import Quicklinks", "Export Quicklinks",
            ])
        #expect(quicklinks.feature.commands.prefix(5).map(\.id) == ["search", "create", "edit", "import", "export"])
    }

    @Test func theDefaultEngineIsTheFirstFallback() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let fallbacks = quicklinks.feature.commands.filter { $0.fallback != nil }
        #expect(fallbacks.map(\.id) == ["open.google", "open.wikipedia", "open.sample-search"])
        #expect(fallbacks.first?.fallback?.title("cats") == "Search Google for \"cats\"")
        #expect(fallbacks.allSatisfy { $0.fallback?.startsOn == true }, "the default engine and marked quicklinks")
        #expect(quicklinks.feature.commands.first { $0.id.hasPrefix("open.") }?.id == "open.google")
    }

    @Test func choosingAnotherEngineMovesItFirst() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.harness.context.settings[QuicklinksSettings.defaultSearch] = "duckduckgo"
        try await quicklinks.harness.settle()
        let fallbacks = quicklinks.feature.commands.filter { $0.fallback != nil }.map(\.id)
        #expect(fallbacks == ["open.duckduckgo", "open.wikipedia", "open.sample-search"])
    }

    @Test func aMissingOrDisabledEngineFallsBackToGoogleThenTheFirstSearch() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.harness.context.settings[QuicklinksSettings.defaultSearch] = "gone"
        #expect(quicklinks.feature.defaultEngine?.id == "google")
        try await quicklinks.feature.setEnabled(false, id: "google")
        #expect(quicklinks.feature.defaultEngine?.id == "duckduckgo")
        #expect(!quicklinks.commandIDs().contains("open.google"))
    }

    @Test func turningFallbacksOffRemovesThemAll() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.harness.context.settings[QuicklinksSettings.offersFallbacks] = false
        try await quicklinks.harness.settle()
        #expect(quicklinks.feature.commands.allSatisfy { $0.fallback == nil })
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func aFallbackOpensTheTypedText() async throws {
        let quicklinks = try await QuicklinksHarness()
        try await quicklinks.harness.runFallback("open.google", text: "swift testing & you")
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == [
                "https://www.google.com/search?q=swift%20testing%20%26%20you"
            ])
    }

    @Test func aFallbackFillsTheFirstArgumentWhenTheHostDidNot() async throws {
        let quicklinks = try await QuicklinksHarness()
        let wikipedia = try #require(quicklinks.feature.entry(id: "wikipedia"))
        let context = ActionContext(
            feature: quicklinks.harness.context, host: quicklinks.harness, query: "Ada Lovelace", launch: .fallback)
        let outcome = try await quicklinks.feature.open(wikipedia, context: context)
        #expect(outcome.kind == .close(hud: nil))
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == [
                "https://en.wikipedia.org/wiki/Special:Search?search=Ada%20Lovelace"
            ])
    }

    @Test func translateTakesTheTextAndAnOptionalLanguage() async throws {
        let quicklinks = try await QuicklinksHarness()
        let translate = try quicklinks.harness.command("open.googletranslate")
        #expect(translate.arguments.map(\.name) == ["Query", "To"])
        #expect(translate.arguments.map(\.isOptional) == [false, true])
        try await quicklinks.harness.run("open.googletranslate", arguments: ["Query": "buenos días"])
        try await quicklinks.harness.run("open.googletranslate", arguments: ["Query": "hello", "To": "fr"])
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == [
                "https://translate.google.com/?sl=auto&text=buenos%20d%C3%ADas&tl=en&op=translate",
                "https://translate.google.com/?sl=auto&text=hello&tl=fr&op=translate",
            ])
    }

    @Test func aRowRootRemembersKeepsItsActionsAfterARelaunch() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let row = try await quicklinks.catalogRow("Sample Docs")
        let snapshot = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(row))
        let actions = quicklinks.harness.rootActions(for: snapshot)
        #expect(actions.map(\.id) == ["open", "open-with", "copy-link", "edit", "duplicate", "toggle", "delete"])
        try await quicklinks.harness.performRoot("open", on: snapshot)
        #expect(quicklinks.fakes.workspace.opened.map(\.absoluteString) == ["https://docs.example.com/guide"])
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func aRowForAQuicklinkThatIsGoneHasNoActions() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let row = try await quicklinks.catalogRow("Sample Docs")
        try await quicklinks.feature.remove(id: "sample-docs")
        #expect(quicklinks.harness.rootActions(for: row).isEmpty)
    }

    @Test func aCommandRowOffersTheQuicklinksActionsAfterRun() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let tracker = try quicklinks.harness.rowActions(ofCommand: "open.sample-tracker")
        #expect(
            tracker.map(\.id) == ["open-with", "copy-link", "edit", "duplicate", "set-default", "toggle", "delete"])
        let google = try quicklinks.harness.rowActions(ofCommand: "open.google")
        #expect(!google.map(\.id).contains("set-default"), "already the default")
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func openWithOnACommandRowUsesTheValuesTyped() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        quicklinks.fakes.workspace.applications = [AppInfo(bundleID: Samples.browserID, name: "Example Browser")]
        let actions = try quicklinks.harness.rowActions(ofCommand: "open.sample-tracker")
        let openWith = try #require(actions.first { $0.id == "open-with" })
        // The host hands the submenu the argument values typed so far.
        let context = ActionContext(
            feature: quicklinks.harness.context, host: quicklinks.harness,
            arguments: CommandArguments(["Issue": "KIT 9"]), launch: .root)
        guard case .submenu(let load) = openWith.kind else {
            Issue.record("expected a submenu")
            return
        }
        let apps = await load(context)
        #expect(apps.map(\.title) == ["Example Browser"])
        guard case .run(let handler) = try #require(apps.first).kind else {
            Issue.record("expected an action")
            return
        }
        _ = try await handler(context)
        let opened = try #require(quicklinks.fakes.workspace.openedWith.first)
        #expect(opened.bundleID == Samples.browserID)
        #expect(opened.urls.map(\.absoluteString) == ["https://tracker.example.com/issues/KIT%209"])
    }
}
