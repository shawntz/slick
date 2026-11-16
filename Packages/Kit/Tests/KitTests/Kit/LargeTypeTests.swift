import Foundation
import Kit
import KitTesting
import Testing

/// A feature returns Large Type as an outcome, through the standard action or its own, and the
/// harness records it as the host shows it: the panel closes and the text is shown.
@Suite("Large Type", .timeLimit(.minutes(1)))
struct LargeTypeTests {
    /// A contact list: the row stands for the name, and one action shows the phone number.
    final class Contacts: Feature, ListSource {
        static let manifest = FeatureManifest(id: "contacts", name: "Contacts", icon: .glyph("C"))
        init(context: FeatureContext) {}

        var commands: [Command] {
            [
                Command(id: "open", title: "Open") { _ in .push(.list(ListPage(self))) },
                Command(id: "code", title: "Show Code") { _ in .showLargeType("482 913") },
            ]
        }

        func load(_ request: ListRequest) async throws -> ListResult {
            ListResult(rows: [
                Row(id: ItemID("contacts", "1"), title: "Sample Person", represents: .text("Sample Person"))
            ])
        }

        func actions(for row: Row) -> [Action] {
            [.copy(row.title), .showInLargeType("555 0100", title: "Show Phone Number in Large Type")]
        }
    }

    @Test func theStandardActionShowsItsTextWithCommandL() async throws {
        let action = Action.showInLargeType("555 0100")
        #expect(action.title == "Show in Large Type")
        #expect(action.shortcut == .largeType)
        #expect(KeyCombo.largeType == KeyCombo(.l, .command))

        let harness = FeatureHarness(Contacts.self)
        try await harness.run("open")
        try await harness.perform("large-type")
        #expect(harness.largeTypeTexts == ["555 0100"])
        #expect(harness.isClosed, "the panel closes before Large Type shows")
    }

    @Test func aCommandCanReturnItAsAnOutcome() async throws {
        let harness = FeatureHarness(Contacts.self)
        try await harness.run("code")
        #expect(harness.largeTypeTexts == ["482 913"])
        #expect(ActionOutcome.showLargeType("482 913").kind == .showLargeType("482 913"))
    }

    @Test func aDetailCanSayWhatItStandsFor() {
        var detail = Detail(.text("555 0100"), represents: .text("555 0100"))
        #expect(detail.represents == .text("555 0100"))
        detail.apply(.append(" more"))
        #expect(detail.represents == .text("555 0100"), "a streamed append keeps it")
        #expect(Detail().represents == nil)
    }
}
