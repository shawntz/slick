import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

@Suite struct RoutingTests {
    @Test func rowsRouteToTheObjectThatMadeThem() async throws {
        let fixture = await RootFixture.ready()
        let root = fixture.root

        let open = try #require(root.row(for: .command(feature: "library", command: "open")))
        #expect(root.actions(for: open).isEmpty)
        #expect(root.featureID(for: open) == "library")
        let hidden = Row(id: .command(feature: "library", command: "hidden"), title: "Hidden Maintenance")
        #expect(root.featureID(for: hidden) == "library")
        let off = Row(id: .command(feature: "garden", command: "water"), title: "Water Plants")
        #expect(root.featureID(for: off) == "garden")

        let book = try #require(root.row(for: ItemID("book", "1")))
        #expect(root.actions(for: book).map(\.title) == ["Open Book"])
        #expect(root.featureID(for: book) == "library")

        let app = try #require(root.row(for: fixture.apps.id("Calendar")))
        #expect(root.actions(for: app).map(\.title) == ["Open App"])
        #expect(root.featureID(for: app) == nil)

        let answer = Row(id: ItemID("count", "1"), title: "2")
        #expect(root.actions(for: answer).map(\.title) == ["Copy Answer"])
        #expect(root.featureID(for: answer) == "library")
        let file = Row(id: ItemID("file", "/tmp/example.txt"), title: "example.txt")
        #expect(root.actions(for: file).map(\.title) == ["Reveal"])

        #expect(root.row(for: ItemID("book", "missing")) == nil)
        #expect(root.actions(for: Row(id: ItemID("unknown", "1"), title: "x")).isEmpty)
        #expect(root.featureID(for: Row(id: ItemID("unknown", "1"), title: "x")) == nil)
        await fixture.shutdown()
    }

    @Test func ownersMatchTheDirectorysOwnRouting() async throws {
        let fixture = await RootFixture.ready()
        for namespace in ["book", "note", "count", "file"] {
            let expected = try #require(fixture.directory.provider(forNamespace: namespace))
            let owner = try #require(fixture.root.plan.owners[namespace])
            #expect(owner.featureID == expected.feature.id)
            #expect(ObjectIdentifier(owner.actions) == ObjectIdentifier(expected.actions))
        }
        await fixture.shutdown()
    }

    @Test func anInstantRowOnScreenIsFoundByID() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        _ = fixture.root.update(query: "=4")
        #expect(fixture.root.row(for: ItemID("count", "4"))?.title == "8")
        fixture.root.end()
        #expect(fixture.root.row(for: ItemID("count", "4")) == nil)
        await fixture.shutdown()
    }
}
