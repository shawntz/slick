import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Hostile input", .timeLimit(.minutes(1)))
@MainActor
struct HostileInputTests {
    static let odd = [
        Person(id: "nul", givenName: "Ana\u{0}Lima", phones: [LabeledValue("mo\nbile", "555\u{0}0100")]),
        Person(id: "rtl", givenName: "\u{202E}Example", familyName: "Name\u{202C}"),
        Person(id: "emoji", givenName: "👩🏽‍💻", nickname: "Coder"),
        Person(id: "zalgo", givenName: "Z\u{0351}\u{0352}a\u{0353}l\u{0354}g\u{0355}o"),
        Person(id: "blank", givenName: "  ", familyName: "\n\t", emails: [LabeledValue("", "   ")]),
        Person(
            id: "huge", givenName: String(repeating: "Long ", count: 2_000),
            phones: [LabeledValue("", String(repeating: "5", count: 100_000))],
            emails: [LabeledValue("", String(repeating: "a", count: 100_000) + "@example.com")],
            addresses: [PostalAddress(street: String(repeating: "Road ", count: 10_000))]),
        Person(id: "", givenName: "No Identifier"),
    ]

    @Test func oddCardsListWithoutBreakingRows() async throws {
        let (harness, _) = await makeHarness(people: Self.odd)
        try await harness.run("search")
        #expect(harness.rows.count == Self.odd.count - 1)
        for row in harness.rows {
            #expect(!row.title.isEmpty)
            #expect(!row.title.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(!(row.subtitle ?? "").contains("\n"))
        }
        #expect(harness.rows.first { $0.id.key == "blank" }?.title == Strings.Rows.noName)
        #expect(harness.rows.first { $0.id.key == "nul" }?.title == "Ana Lima")
        try await harness.setQuery("coder")
        #expect(harness.titles == ["👩🏽‍💻"])
        #expect(harness.issues.isEmpty)
    }

    @Test func hugeValuesGetNoReachingActionsAndStayCheap() async throws {
        let (harness, _) = await makeHarness(people: Self.odd)
        try await harness.run("search")
        try harness.select(ItemID(PeopleSnapshot.namespace, "huge"))
        let start = ContinuousClock.now
        let ids = harness.actionIDs
        let elapsed = ContinuousClock.now - start
        #expect(!ids.contains("call") && !ids.contains("email") && !ids.contains("open-address-in-maps"))
        #expect(ids.contains("copy-phone"))
        #expect(elapsed < .milliseconds(50))
        let detail = try #require(try await harness.loadDetail())
        #expect(!detail.metadata.isEmpty)
    }

    @Test func aNullCharacterNeverReachesALink() async throws {
        let (harness, _) = await makeHarness(people: Self.odd)
        try await harness.run("search")
        try harness.select(ItemID(PeopleSnapshot.namespace, "nul"))
        try await harness.perform("call")
        #expect(harness.fakes.workspace.opened.map(\.absoluteString) == ["tel:5550100"])
        let entryTitle = Strings.Actions.entry(label: "mo\nbile", value: "555\u{0}0100")
        #expect(!entryTitle.contains("\n") && !entryTitle.contains("\u{0}"))
    }
}
