import Foundation
import Kit
import KitTesting
import Testing

/// The host rules the harness reproduces, checked against a small feature built for the purpose.
@Suite("FeatureHarness")
struct FeatureHarnessTests {
    final class Probe: Feature, ListSource {
        static let manifest = FeatureManifest(id: "probe", name: "Probe", icon: .glyph("P"))
        var rows = ["Alpha", "Beta", "Gamma"]
        var loads = 0

        init(context: FeatureContext) {}

        var commands: [Command] {
            [
                Command(id: "list", title: "List") { _ in .push(.list(ListPage(self))) },
                Command(id: "chain", title: "Chain") { _ in .run(.command(feature: "probe", command: "list")) },
                Command(id: "elsewhere", title: "Elsewhere") { _ in
                    .run(.command(feature: "other", command: "x"), arguments: ["a": "1"])
                },
                Command(
                    id: "args", title: "Args",
                    arguments: [
                        CommandArgument("q"), CommandArgument("n", isOptional: true, defaultValue: "3"),
                        CommandArgument("o", isOptional: true),
                    ]
                ) { context in
                    context.showToast(
                        .success(
                            "\(context.arguments["q"] ?? "")/\(context.arguments["n"] ?? "")/\(context.arguments["o"] ?? "-")"
                        ))
                    return .keepOpen
                },
            ]
        }

        func load(_ request: ListRequest) async throws -> ListResult {
            loads += 1
            return ListResult(rows: rows.map { Row(id: ItemID("probe", $0), title: $0) })
        }

        func actions(for row: Row) -> [Action] {
            [
                Action("Remove", style: .destructive, confirmation: Confirmation("Remove?")) { context in
                    self.rows.removeAll { $0 == row.title }
                    context.reload()
                    return .keepOpen
                },
                Action("Ask") { context in
                    let yes = await context.confirm(Confirmation("Sure?"))
                    context.setQuery(yes ? "a" : "b")
                    return .popToRoot
                },
                .submenu("More") { _ in [.copy(row.title)] },
            ]
        }
    }

    @Test func fillsDefaultsAndRejectsMissingRequiredArguments() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("args", arguments: ["q": "x"])
        #expect(harness.toasts.last?.title == "x/3/-")
        await #expect(throws: HarnessError.missingArgument("q")) { try await harness.run("args") }
        await #expect(throws: HarnessError.noSuchCommand("nope")) { try await harness.run("nope") }
    }

    @Test func runsItsOwnChainedCommandsAndRecordsOthers() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("chain")
        #expect(harness.rows.count == 3)
        try await harness.run("elsewhere")
        #expect(harness.commandRuns.map(\.id.rawValue) == ["cmd:probe.list", "cmd:other.x"])
        #expect(harness.commandRuns.last?.arguments == ["a": "1"])
    }

    @Test func keepsTheSelectionVisibleAndReloadsAfterAnAction() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("list")
        try harness.select(title: "Beta")
        try await harness.perform("Remove")
        #expect(harness.rows.map(\.title) == ["Alpha", "Gamma"])
        #expect(harness.selectedRow?.title == "Alpha")
        #expect(harness.feature.loads == 2)
        try await harness.setQuery("gam")
        #expect(harness.selectedRow?.title == "Gamma")
        #expect(harness.feature.loads == 2, "host filtering never calls the source per keystroke")
    }

    @Test func recordsQuestionsQueryChangesAndNavigation() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("list")
        harness.confirmationAnswer = false
        try await harness.perform("Ask")
        #expect(harness.queryChanges == ["b"])
        #expect(harness.confirmations.map(\.title) == ["Sure?"])
        #expect(harness.pages.isEmpty)
    }

    @Test func distinguishesSubmenusFromActions() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("list")
        await #expect(throws: HarnessError.isSubmenu("More")) { try await harness.perform("More") }
        await #expect(throws: HarnessError.notASubmenu("Ask")) { try await harness.submenu("Ask") }
        #expect(try await harness.submenu("More").map(\.id) == ["copy"])
        #expect(throws: HarnessError.noSuchRow("Delta")) { try harness.select(title: "Delta") }
    }
}
