import Foundation
import Kit
import KitTesting
import Testing

/// Settings buttons, toast buttons, Tab, typed text, row actions on command rows and expired rows.
@Suite("FeatureHarness: controls")
struct HarnessControlsTests {
    final class Panel: Feature, CatalogSource {
        static let manifest = FeatureManifest(id: "panel", name: "Panel", icon: .glyph("P"))
        private(set) var cleared = 0
        private let opened: Date

        init(context: FeatureContext) {
            opened = context.clock.now
        }

        let namespace = "panel"
        var catalogSources: [any CatalogSource] { [self] }

        func rows() async throws -> [Row] {
            [
                Row(id: ItemID(namespace, "now"), title: "Now", expires: opened + 60),
                Row(id: ItemID(namespace, "later"), title: "Later"),
            ]
        }

        func actions(for row: Row) -> [Action] { [] }

        var commands: [Command] {
            [
                Command(id: "ask", title: "Ask", arguments: [CommandArgument("question")], takesRootQueryOnTab: true) {
                    context in
                    let toast = Toast(.info, "Asked \(context.query)", action: ToastAction("Undo") { _ in .popToRoot })
                    context.showToast(toast)
                    return .keepOpen
                }
                .withRowActions { [Action("Edit", id: "edit") { _ in .keepOpen }] }
            ]
        }

        var settingsPane: SettingsPane? {
            SettingsPane(items: [
                .button("Clear", confirmation: Confirmation("Clear?")) { context in
                    self.cleared += 1
                    context.showToast(.success("Cleared"))
                }
            ])
        }
    }

    @Test func aSettingsButtonRunsWithAContext() async throws {
        let harness = FeatureHarness(Panel.self)
        try await harness.pressSettingsButton("Clear")
        #expect(harness.feature.cleared == 1)
        #expect(harness.toasts.map(\.title) == ["Cleared"])
        #expect(harness.confirmations.map(\.title) == ["Clear?"])
        await #expect(throws: HarnessError.noSuchSettingsButton("Reset")) {
            try await harness.pressSettingsButton("Reset")
        }
    }

    @Test func tabAndFallbacksPassTheTypedText() async throws {
        let harness = FeatureHarness(Panel.self)
        let completing = Row(id: ItemID("panel", "x"), title: "x", completion: "x = 1")
        #expect(try await harness.pressTab("x", on: completing) == "x = 1")
        #expect(harness.toasts.isEmpty, "a completion wins over the Tab command")
        #expect(try await harness.pressTab("why") == nil)
        #expect(harness.visibleToast?.title == "Asked why")
        try await harness.runFallback("ask", text: "how")
        #expect(harness.visibleToast?.title == "Asked how")
        #expect(try await harness.performToastAction().kind == .popToRoot)
    }

    @Test func commandRowsOfferTheirOwnActions() throws {
        let harness = FeatureHarness(Panel.self)
        #expect(try harness.rowActions(ofCommand: "ask").map(\.id) == ["edit"])
        let commandRow = Row(id: .command(feature: "panel", command: "ask"), title: "Ask")
        #expect(harness.rootActions(for: commandRow).map(\.id) == ["edit"])
    }

    @Test func expiredCatalogRowsDropOut() async throws {
        let harness = FeatureHarness(Panel.self)
        #expect(try await harness.catalogRows().map(\.title) == ["Now", "Later"])
        harness.fakes.clock.advance(by: .seconds(61))
        #expect(try await harness.catalogRows().map(\.title) == ["Later"])
    }
}
