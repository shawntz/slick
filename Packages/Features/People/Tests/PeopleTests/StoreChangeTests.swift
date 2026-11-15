import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Store changes", .timeLimit(.minutes(1)))
@MainActor
struct StoreChangeTests {
    @Test func aPersonAddedWhileTheListIsOpenAppears() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        try await harness.setQuery("nadia")
        #expect(harness.rows.isEmpty)

        store.save(Person(id: "p-nadia", givenName: "Nadia", familyName: "Example"))
        try await harness.waitForChange()
        #expect(harness.titles == ["Nadia Example"])
        #expect(store.peopleReads == 2)
    }

    @Test func anEditAndADeletionShowWhileTheListIsOpen() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        var renamed = Cast.bruno
        renamed.familyName = "Silva"
        store.save(renamed)
        try await harness.waitForChange()
        #expect(harness.titles.contains("Bruno Silva"))
        #expect(!harness.titles.contains("Bruno Costa"))

        store.delete(id: Cast.ana.id)
        try await harness.waitForChange()
        #expect(!harness.titles.contains("Ana Lima"))
        #expect(
            harness.rootActions(for: Row(id: personID(Cast.ana), title: "Ana Lima")).map(\.id) == ["open-in-contacts"])
    }

    @Test func theSelectedPersonKeepsTheirActionsAfterAChange() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        try harness.select(personID(Cast.bruno))
        var updated = Cast.bruno
        updated.emails = []
        store.save(updated)
        try await harness.waitForChange()
        #expect(harness.selectedRow?.id == personID(Cast.bruno))
        #expect(!harness.actionIDs.contains("email"))
    }

    @Test func rootSearchFollowsTheStore() async throws {
        let (harness, store) = await makeHarness()
        #expect(try await harness.catalogRows().count == Cast.all.count)
        let before = harness.feature.directory.changes.generation
        store.save(Person(id: "p-nadia", givenName: "Nadia"))
        await waitUntil { harness.feature.directory.changes.generation > before }
        #expect(try await harness.catalogRows().map(\.title).contains("Nadia"))
        #expect(store.peopleReads == 2)
    }

    @Test func aBurstOfChangesEndsWithTheLastState() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        for index in 0..<20 {
            store.save(Person(id: "burst-\(index)", givenName: "Burst", familyName: "\(index)"))
        }
        await waitUntil { harness.feature.directory.snapshot?.people.count == Cast.all.count + 20 }
        await harness.feature.directory.waitUntilIdle()
        try await harness.settle()
        try await harness.reloadPage()
        #expect(harness.rows.count == Cast.all.count + 20)
        #expect(store.peopleReads < 22)
    }

    @Test func aStoreThatFailsKeepsWhatWasShown() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        store.failure = .unreadable
        store.save(Person(id: "p-nadia", givenName: "Nadia"))
        await waitUntil { store.peopleReads == 2 }
        await harness.feature.directory.waitUntilIdle()
        #expect(harness.feature.directory.snapshot?.people.count == Cast.all.count)
        #expect(harness.feature.directory.isFollowing)
    }

    @Test func aChangeAlsoDropsCachedPhotos() async throws {
        let photo = syntheticPNG(width: 600, height: 400)
        var ana = Cast.ana
        ana.hasPhoto = true
        let (harness, store) = await makeHarness(people: [ana], photos: [ana.id: photo])
        try await harness.run("search")
        _ = try await harness.loadDetail()
        _ = try await harness.loadDetail()
        #expect(store.photoReads == 1)
        store.save(ana)
        try await harness.waitForChange()
        _ = try await harness.loadDetail()
        #expect(store.photoReads == 2)
    }
}
