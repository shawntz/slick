import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Settings and the Search Quicklinks page", .timeLimit(.minutes(1)))
@MainActor
struct SettingsTests {
    @Test func thePaneOffersTheExpectedChoicesWithSafeDefaults() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let pane = try #require(quicklinks.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        #expect(
            items.map(\.title) == [
                Strings.defaultEngineSetting, Strings.fallbacksSetting, Strings.addressesSetting, Strings.restoreButton,
                Strings.revealButton,
            ])
        guard case .picker(let key, let options) = items[0].control else {
            Issue.record("expected a picker")
            return
        }
        #expect(key.name == "defaultSearch")
        #expect(key.defaultValue == .string("google"))
        #expect(options.count == quicklinks.feature.searchEngines.count)
        #expect(options.first == SettingsOption(title: "Search Google", value: .string("google")))
        #expect(QuicklinksSettings.offersFallbacks.defaultValue && QuicklinksSettings.detectsAddresses.defaultValue)
    }

    @Test func thePickerFollowsWhichSearchesAreOn() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.feature.setEnabled(false, id: "google")
        let items = try #require(quicklinks.feature.settingsPane).sections.flatMap(\.items)
        guard case .picker(_, let options) = items[0].control else {
            Issue.record("expected a picker")
            return
        }
        #expect(!options.contains { $0.value == .string("google") })
        #expect(options.contains { $0.value == .string("sample-search") })
    }

    @Test func showFileRevealsTheQuicklinksFile() async throws {
        let quicklinks = try await QuicklinksHarness()
        try await quicklinks.harness.pressSettingsButton(Strings.revealButton)
        #expect(quicklinks.fakes.workspace.revealed == [quicklinks.fileURL])
    }

    @Test func theListHasTwoSectionsAFilterAndADetailPane() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.harness.run("search")
        #expect(quicklinks.harness.sections.map(\.title) == [Strings.ownSection, Strings.builtInSection])
        #expect(quicklinks.harness.sections[0].rows.map(\.title) == ["Sample Docs", "Sample Search", "Sample Tracker"])
        #expect(quicklinks.harness.page?.dropdown?.options.map(\.id) == ["all", "own", "builtin", "off"])
        try await quicklinks.harness.setFilter("own")
        #expect(quicklinks.harness.sections.map(\.title) == [Strings.ownSection])
        try await quicklinks.harness.setFilter("all")

        try await quicklinks.harness.setQuery("wikipedia")
        let wiki = try #require(quicklinks.harness.rows.first)
        #expect(wiki.title == "Search Wikipedia")
        #expect(wiki.accessories.first == .text("wiki"))
        #expect(wiki.accessories.contains(.icon(.symbol("arrow.turn.down.right"), tooltip: Strings.fallbackTooltip)))
        let detail = try #require(try await quicklinks.harness.loadDetail())
        #expect(detail.body == .text(DefaultSearches.quicklink(id: "wikipedia")?.link ?? "", monospaced: true))
        #expect(detail.metadata.contains(.label(Strings.detailFallback, value: Strings.detailFallbackOn)))
        #expect(detail.metadata.contains(.label(Strings.detailOpensWith, value: Strings.detailDefaultApp)))
        #expect(detail.metadata.contains(.tags(Strings.detailArguments, [Tag("Query")])))
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func theDetailNamesTheAppAQuicklinkOpensWith() async throws {
        var docs = Samples.docs
        docs.openWith = Samples.browserID
        let quicklinks = try await QuicklinksHarness(file: QuicklinkFile(quicklinks: [docs]))
        quicklinks.fakes.workspace.installed = [AppInfo(bundleID: Samples.browserID, name: "Example Browser")]
        try await quicklinks.selectInList("Sample Docs")
        let detail = try #require(try await quicklinks.harness.loadDetail())
        #expect(
            detail.metadata.contains(
                .label(Strings.detailOpensWith, value: "Example Browser", icon: .app(bundleID: Samples.browserID))))
    }

    @Test func theEmptyStateOffersToCreateAQuicklink() async throws {
        let empty = QuicklinkFile(quicklinks: [], removedDefaults: DefaultSearches.all.map(\.id))
        let quicklinks = try await QuicklinksHarness(file: empty)
        try await quicklinks.harness.run("search")
        #expect(quicklinks.harness.rows.isEmpty)
        #expect(quicklinks.harness.page?.emptyState?.title == Strings.emptyTitle)
        #expect(quicklinks.harness.actions().map(\.id) == ["create"])
    }

    @Test func theManifestNamesTheFeature() {
        let manifest = QuicklinksFeature.manifest
        #expect(manifest.id == "quicklinks")
        #expect(manifest.permissions.map(\.permission) == [.accessibility], "only for links that read the selection")
        #expect(manifest.permissions.allSatisfy { $0.reason.hasPrefix("Read ") })
        #expect(manifest.isEnabledByDefault)
        #expect(FeatureValidator.validate(manifest).isEmpty)
    }
}
