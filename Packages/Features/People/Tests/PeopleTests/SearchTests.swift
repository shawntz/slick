import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Search Contacts", .timeLimit(.minutes(1)))
@MainActor
struct SearchTests {
    @Test func theListShowsEveryoneSortedByName() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        #expect(
            harness.titles == [
                "Ana Lima", "Bruno Costa", "Example Bakery", "Example Workshop", "Léa Müller", "Дарья Иванова",
                "王 伟", "田中 宏",
            ])
        #expect(harness.fakes.fuzzyIndex.builtIndexSizes == [Cast.all.count])
        #expect(harness.issues.isEmpty)
    }

    @Test(arguments: [
        ("ana lima", "Ana Lima"), ("lima ana", "Ana Lima"), ("lima", "Ana Lima"), ("annie", "Ana Lima"),
        ("lea muller", "Léa Müller"), ("muller", "Léa Müller"), ("иванова", "Дарья Иванова"),
        ("ivanova", "Дарья Иванова"), ("tanaka", "田中 宏"), ("たなか", "田中 宏"), ("wang wei", "王 伟"),
        ("王", "王 伟"), ("workshop", "Example Workshop"), ("studio", "Ana Lima"), ("designer", "Ana Lima"),
        ("bruno@example", "Bruno Costa"), ("5550100101", "Ana Lima"),
    ])
    func searchFindsPeopleAcrossNameOrdersAndScripts(_ query: String, _ expected: String) async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        try await harness.setQuery(query)
        #expect(harness.titles.first == expected, "\(query) found \(harness.titles)")
    }

    @Test func aCompanyWithoutAPersonsNameIsFoundAndTitledByItsName() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        try await harness.setQuery("example")
        #expect(Set(harness.titles).isSuperset(of: ["Example Bakery", "Example Workshop"]))
        let row = try #require(harness.rows.first { $0.title == "Example Workshop" })
        #expect(row.icon == .symbol("building.2.crop.circle"))
    }

    @Test func twoPeopleWithTheSameNameBothShowAndDifferBelow() async throws {
        let twins = [
            Person(id: "t1", givenName: "Sam", familyName: "Reed", emails: [LabeledValue("", "sam@example.com")]),
            Person(id: "t2", givenName: "Sam", familyName: "Reed", organization: "Example Labs"),
        ]
        let (harness, _) = await makeHarness(people: twins)
        try await harness.run("search")
        try await harness.setQuery("sam reed")
        #expect(harness.titles == ["Sam Reed", "Sam Reed"])
        #expect(Set(harness.rows.compactMap(\.subtitle)) == ["sam@example.com", "Example Labs"])
        #expect(Set(harness.rows.map(\.id)).count == 2)
    }

    @Test func aCardTheStoreReturnsTwiceShowsOnce() async throws {
        let (harness, _) = await makeHarness(people: [Cast.ana, Cast.bruno, Cast.ana])
        try await harness.run("search")
        #expect(harness.titles == ["Ana Lima", "Bruno Costa"])
    }

    @Test func aFallbackOpensTheListWithTheTypedText() async throws {
        let (harness, _) = await makeHarness()
        let command = try harness.command("search")
        #expect(command.fallback?.title("ana") == "Search Contacts for \u{201C}ana\u{201D}")
        try await harness.runFallback("search", text: "bruno")
        #expect(harness.page?.query == "bruno")
        #expect(harness.titles == ["Bruno Costa"])
    }

    @Test func anEmptyStoreSaysSo() async throws {
        let (harness, _) = await makeHarness(people: [])
        try await harness.run("search")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == Strings.List.emptyTitle)
    }

    @Test func rowsAreLearnOnlyAndKeyedByTheStoreIdentifier() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        let row = try #require(harness.rows.first)
        #expect(row.id == personID(Cast.ana))
        #expect(row.memory == .learnOnly)
        #expect(row.payload == nil)
    }
}
