import Foundation
import Kit
import KitTesting
import Testing

@Suite("FeatureValidator")
struct FeatureValidatorTests {
    final class Broken: Feature, CatalogSource {
        static let manifest = FeatureManifest(id: "Broken Feature", name: " ", icon: .symbol("xmark"))
        init(context: FeatureContext) {}

        let namespace = "cmd"
        func rows() async throws -> [Row] { [] }
        func actions(for row: Row) -> [Action] { [] }

        var commands: [Command] {
            let four = ["a", "b", "c", "d"].map { CommandArgument($0) }
            return [
                Command(id: "same", title: "One", arguments: four) { _ in .keepOpen },
                Command(id: "same", title: "", requires: [.accessibility]) { _ in .keepOpen },
                Command(id: "bad id", title: "Three", arguments: [CommandArgument("x", kind: .dropdown([]))]) { _ in
                    .keepOpen
                },
            ]
        }

        private let other = OtherSource()
        var catalogSources: [any CatalogSource] { [self, other] }
        var hotkeyPresets: [HotkeyPreset] {
            [HotkeyPreset(id: "p", name: "P", bindings: ["same": KeyCombo(.a), "nope": KeyCombo(.a)])]
        }
    }

    final class OtherSource: CatalogSource {
        let namespace = "cmd"
        func rows() async throws -> [Row] { [] }
        func actions(for row: Row) -> [Action] { [] }
    }

    /// One object that is a catalog source, an instant provider and a suggestion trigger under one
    /// namespace, which is allowed.
    final class Shared: Feature, CatalogSource, InstantProvider, SuggestionTrigger {
        static let manifest = FeatureManifest(id: "shared", name: "Shared", icon: .glyph("S"))
        init(context: FeatureContext) {}

        let namespace = "shared"
        let id = "soon"
        let prior = AcceptancePrior(accepts: 1, rejects: 1)
        func rows() async throws -> [Row] { [] }
        func answer(for query: String) -> InstantAnswer? { nil }
        func suggestions(at date: Date) async throws -> [Suggestion] { [] }
        func actions(for row: Row) -> [Action] { [] }

        var catalogSources: [any CatalogSource] { [self] }
        var liveProviders: [LiveProvider] { [.instant(self)] }
        var suggestionTriggers: [any SuggestionTrigger] { [self] }
    }

    /// Makes its provider anew on each read, which the host cannot keep.
    final class Unstable: Feature {
        static let manifest = FeatureManifest(id: "unstable", name: "Unstable", icon: .glyph("U"))
        init(context: FeatureContext) {}
        var catalogSources: [any CatalogSource] { [FreshSource()] }
    }

    final class FreshSource: CatalogSource {
        let namespace = "fresh"
        func rows() async throws -> [Row] { [] }
        func actions(for row: Row) -> [Action] { [] }
    }

    @Test func reportsEveryBrokenRule() {
        let issues = Set(FeatureHarness(Broken.self).issues.map(\.message))
        let expected: Set<String> = [
            "feature id \"Broken Feature\" must be a lowercase letter, then lowercase letters, digits or \"-\"",
            "feature \"Broken Feature\" has no name",
            "command \"same\" has 4 arguments; the search bar holds at most 3",
            "command \"same\" has no title",
            "command \"same\" requires Accessibility, which the manifest does not list",
            "command \"bad id\": id must use letters, digits, \".\", \"-\" or \"_\"",
            "command \"bad id\": dropdown argument \"x\" has no options",
            "command \"same\" is declared twice",
            "namespace \"cmd\" is reserved for root search",
            "namespace \"cmd\" is used by more than one source",
            "hotkey preset \"p\" binds \"nope\", which is not a command",
            "hotkey preset \"p\" uses A for more than one command",
        ]
        #expect(issues == expected)
    }

    final class AppSource: CatalogSource {
        let namespace = ItemID.ReservedNamespace.app
        func rows() async throws -> [Row] { [] }
        func actions(for row: Row) -> [Action] { [] }
    }

    final class Apps: Feature {
        static let manifest = FeatureManifest(id: "apps", name: "Apps", icon: .glyph("A"))
        let source = AppSource()
        init(context: FeatureContext) {}
        var catalogSources: [any CatalogSource] { [source] }
    }

    final class NotApps: Feature {
        static let manifest = FeatureManifest(id: "launchpad", name: "Launchpad", icon: .glyph("L"))
        let source = AppSource()
        init(context: FeatureContext) {}
        var catalogSources: [any CatalogSource] { [source] }
    }

    @Test func onlyTheAppsFeatureMayUseTheAppNamespace() {
        #expect(FeatureHarness(Apps.self).issues.isEmpty)
        #expect(FeatureHarness(NotApps.self).issues.map(\.message) == ["namespace \"app\" is reserved for root search"])
        #expect(!ItemID.ReservedNamespace.allows(ItemID.ReservedNamespace.command, forFeature: "apps"))
    }

    @Test func oneObjectMayServeOneNamespaceInSeveralRoles() {
        #expect(FeatureHarness(Shared.self).issues.isEmpty)
    }

    @Test func reportsSourcesMadeAnewOnEachRead() {
        #expect(
            FeatureHarness(Unstable.self).issues.map(\.message) == [
                "catalogSources returns new objects on each read; keep them in stored properties"
            ])
    }

    @Test func checksActionPermissionsAgainstTheManifest() {
        let manifest = FeatureManifest(id: "demo", name: "Demo", icon: .glyph("D"))
        let issues = FeatureValidator.validate(actions: [.paste("x"), .copy("x"), .copy("y")], manifest: manifest)
        #expect(
            issues.map(\.message) == [
                "action \"paste\" requires Accessibility, which the manifest does not list",
                "action \"copy\" appears twice in one list",
            ])
    }
}
