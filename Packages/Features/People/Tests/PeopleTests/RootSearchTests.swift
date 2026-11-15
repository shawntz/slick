import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Root search", .timeLimit(.minutes(1)))
@MainActor
struct RootSearchTests {
    @Test func peopleJoinRootSearchByNameInTheirOwnNamespace() async throws {
        let (harness, _) = await makeHarness()
        let rows = try await harness.catalogRows()
        #expect(rows.count == Cast.all.count)
        #expect(rows.allSatisfy { $0.id.namespace == "contact" && $0.memory == .learnOnly && $0.payload == nil })
        let ana = try #require(rows.first { $0.id == personID(Cast.ana) })
        #expect(ana.title == "Ana Lima")
        #expect(ana.keywords.contains("Annie"))
        #expect(ana.keywords.contains("Example Studio"))
        #expect(harness.feature.catalogSources.map(\.namespace) == ["contact"])
        #expect(harness.issues.isEmpty)
    }

    @Test func rootSearchKeepsNamesOnly() async throws {
        let (harness, _) = await makeHarness()
        for row in try await harness.catalogRows() {
            for word in row.keywords {
                #expect(!word.contains("@"), "\(row.title) carries \(word)")
                #expect(word.filter(\.isNumber).count < 4, "\(row.title) carries \(word)")
            }
        }
    }

    @Test func theSettingHidesPeopleFromRootSearch() async throws {
        let (harness, store) = await makeHarness()
        let catalog = try #require(harness.feature.catalogSources.first)
        #expect(catalog.reloadsOnSettings.map(\.name) == ["showsInRootSearch"])
        harness.context.settings[PeopleSettings.showsInRootSearch] = false
        #expect(try await harness.catalogRows().isEmpty)
        #expect(store.peopleReads == 0)
        harness.context.settings[PeopleSettings.showsInRootSearch] = true
        #expect(try await harness.catalogRows().count == Cast.all.count)
    }

    @Test func aRootRowOffersThePersonsActions() async throws {
        let (harness, _) = await makeHarness()
        let bruno = try #require(try await harness.catalogRows().first { $0.id == personID(Cast.bruno) })
        let actions = harness.rootActions(for: bruno)
        #expect(actions.first?.id == "open-in-contacts")
        try await harness.performRoot("call", on: bruno)
        #expect(harness.fakes.workspace.opened == [URL(string: "tel:5550100")])
        #expect(harness.issues.isEmpty)
    }

    @Test func rootSearchAndTheListShareOneRead() async throws {
        let (harness, store) = await makeHarness()
        async let catalog = harness.catalogRows()
        try await harness.run("search")
        #expect(try await catalog.count == Cast.all.count)
        #expect(store.peopleReads == 1)
    }

    @Test func tabFromRootOpensTheListWithTheText() async throws {
        let (harness, _) = await makeHarness()
        #expect(try harness.command("search").takesRootQueryOnTab)
        _ = try await harness.pressTab("lima")
        #expect(harness.page?.query == "lima")
        #expect(harness.titles == ["Ana Lima"])
    }
}
