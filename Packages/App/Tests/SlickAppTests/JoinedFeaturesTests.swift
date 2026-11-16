import Foundation
import Host
import Kit
import KitHosting
import Root
import Testing

@testable import SlickApp

/// What joining sixteen features into one app must not break: titles, namespaces and universal
/// actions that two features share, fallbacks that start on, and the selftest's own lists.
@Suite("Joined features", .timeLimit(.minutes(2)))
struct JoinedFeaturesTests {
    /// Every feature switched on, in the selftest environment, without a panel.
    private func assembly(_ folder: CompositionTests.Folder) async -> Assembly {
        let assembly = Assembly(
            .init(environment: .selftest, dataRoot: folder.url, rootStorage: .inMemory, makesPanel: false))
        await assembly.start(prewarm: false)
        for entry in assembly.runtime.features where !entry.isEnabled {
            await assembly.runtime.preferences.setEnabled(true, feature: entry.id)
        }
        _ = await SelfTest.within(.seconds(20)) { await assembly.ready() }
        return assembly
    }

    @Test func noTwoFeaturesShareACommandTitle() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = await assembly(folder)
        var owners: [String: [String]] = [:]
        for entry in assembly.runtime.features {
            for command in entry.commands {
                owners[command.command.title.lowercased(), default: []].append(command.id.rawValue)
            }
        }
        let shared = owners.filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "\(shared)")
        await assembly.shutdown()
    }

    @Test func noTwoFeaturesShareANamespace() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = await assembly(folder)
        var owners: [String: Set<String>] = [:]
        for entry in assembly.runtime.features {
            let namespaces =
                entry.catalogSources.map(\.namespace) + entry.liveProviders.map(\.namespace)
                + entry.suggestionTriggers.map(\.namespace)
            for namespace in namespaces { owners[namespace, default: []].insert(entry.id) }
        }
        let shared = owners.filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "\(shared)")
        // Root search keeps `cmd` for itself and `app` for the Apps feature.
        #expect(owners[ItemID.ReservedNamespace.command] == nil)
        #expect(owners["app"] == ["apps"])
        await assembly.shutdown()
    }

    @Test func noTwoFeaturesOfferAUniversalActionWithTheSameTitle() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = await assembly(folder)
        let selections: [Selection] = [
            .text("example"), .text("two words"), .url(URL(string: "https://example.com")!),
            .files([URL(filePath: "/tmp/example.txt")]),
        ]
        for selection in selections {
            var owners: [String: Set<String>] = [:]
            for entry in assembly.runtime.features {
                for provider in entry.universalActions where provider.accepts.contains(selection.kind) {
                    for action in provider.actions(selection) { owners[action.title, default: []].insert(entry.id) }
                }
            }
            let shared = owners.filter { $0.value.count > 1 }
            #expect(shared.isEmpty, "\(selection): \(shared)")
        }
        await assembly.shutdown()
    }

    /// A new feature's fallback starts off, so joining eight features adds no row under every
    /// query that finds nothing. The web searches the user expects are the ones that start on.
    @Test func onlyTheWebSearchFallbacksStartOn() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = await assembly(folder)
        let startOn = assembly.runtime.features.flatMap(\.commands).filter { $0.command.fallback?.startsOn == true }
        #expect(Set(startOn.map(\.featureID)) == ["quicklinks"])
        let fallbacks = assembly.runtime.features.flatMap(\.commands).filter { $0.command.fallback != nil }
        #expect(Set(fallbacks.map(\.featureID)).isSuperset(of: ["dictionary", "schedule", "contacts", "ai"]))
        await assembly.shutdown()
    }

    /// Each command the selftest finds by another query is still taken over by its title, and is
    /// found by the other query. When a feature changes, the list must change with it.
    @Test func everyTitleTakenOverIsStillTakenOverAndFoundOtherwise() async throws {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = await assembly(folder)
        for (id, other) in SelfTest.titlesTakenOver {
            let entry = try #require(assembly.runtime.command(id), "\(id)")
            let byTitle = assembly.root.update(query: entry.command.title)
            #expect(!byTitle.rows.prefix(5).contains { $0.id == id }, "\(id) is found by its title again")
            let byOther = assembly.root.update(query: other.query)
            #expect(byOther.rows.prefix(5).contains { $0.id == id }, "\(id) is not found by \"\(other.query)\"")
            assembly.root.end()
        }
        await assembly.shutdown()
    }

    @Test func theSelftestFailsOnANewPendingIssueAndPrintsEveryOne() {
        // No rule is pending in Kit now, so the test brings its own: a command titled "Act".
        let rule: ([Command]) -> [FeatureIssue] = { commands in
            commands.filter { $0.title == "Act" }.map { FeatureIssue("command \"\($0.id)\" acts") }
        }
        let act = Command(id: "act", title: "Act", showsInRoot: false) { _ in .keepOpen }
        let safe = Command(id: "safe", title: "Safe", showsInRoot: false, allowsDeepLinks: false) { _ in .keepOpen }
        let features: [(id: String, commands: [Command])] = [("one", [act, safe]), ("two", [act])]
        let issue = rule([act])[0].description

        let fresh = SelfTest.pendingIssues(features, known: [:], rule: rule)
        #expect(fresh.lines.count == 2)
        #expect(fresh.lines.allSatisfy { $0.hasPrefix("pending ") })
        #expect(fresh.failures.count == 2)
        #expect(fresh.known == 0)
        #expect(SelfTest.pendingIssues(features, known: [:]).lines.isEmpty)

        let known = SelfTest.pendingIssues(features, known: ["one": [issue]], rule: rule)
        #expect(known.lines.count == 2)
        #expect(known.lines[0].hasSuffix("(known)"))
        #expect(known.failures == ["feature two has a new pending issue: \(issue)"])
        #expect(known.known == 1)
    }

    @Test func theJoinedAppHasNoPendingIssueToday() async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let report = await SelfTest.checkComposition(dataRoot: folder.url)
        #expect(report.pending.isEmpty, "\(report.pending)")
        #expect(report.facts.contains("pending=0"))
        #expect(report.facts.contains("taken-over=\(SelfTest.titlesTakenOver.count)"))
    }
}
