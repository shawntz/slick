import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

@Suite struct CatalogTests {
    @Test func commandsCatalogRowsAndBuiltInsAreSearchable() async throws {
        let fixture = await RootFixture.ready()
        #expect(fixture.results("open lib") == ["Open Library"])
        #expect(fixture.results("garden").first == "Garden Atlas")
        #expect(fixture.results("calendar") == ["Calendar"])
        // Hidden commands and commands of a feature that is off stay out.
        #expect(fixture.results("hidden maint").isEmpty)
        #expect(fixture.results("water plants").isEmpty)
        let open = try #require(fixture.root.row(for: .command(feature: "library", command: "open")))
        #expect(open.subtitle == "Library")
        #expect(open.icon == .symbol("books.vertical"))
        await fixture.shutdown()
    }

    @Test func keysAreTheEngineKeysOfTheIDs() {
        let id = ItemID("book", "1")
        #expect(ItemKey(id: id.rawValue).rawValue == id.engineKey)
    }

    @Test func aChangeSignalReloadsTheSource() async throws {
        let fixture = await RootFixture.ready()
        #expect(fixture.results("pottery").isEmpty)
        fixture.library.books.rows.append(Row(id: ItemID("book", "3"), title: "Pottery Basics"))
        fixture.library.books.signal.send()
        await fixture.settle()
        #expect(fixture.results("pottery") == ["Pottery Basics"])
        await fixture.shutdown()
    }

    @Test func aSettingInReloadsOnSettingsReloadsTheSource() async throws {
        let fixture = await RootFixture.ready()
        let loads = fixture.library.books.loads
        let context = fixture.fakes.context(featureID: LibraryFeature.manifest.id)
        context.settings[LibrarySettings.sortByAuthor] = true
        await fixture.settle()
        #expect(fixture.library.books.loads == loads + 1)
        await fixture.shutdown()
    }

    @Test func aSourceThatThrowsKeepsItsRows() async throws {
        let fixture = await RootFixture.ready()
        fixture.library.books.rows = []
        fixture.library.books.failure = ExampleFailure()
        fixture.library.books.signal.send()
        await fixture.settle()
        #expect(fixture.results("example book") == ["Example Book"])

        fixture.library.books.failure = nil
        fixture.library.books.signal.send()
        await fixture.settle()
        #expect(fixture.results("example book").isEmpty)
        await fixture.shutdown()
    }

    @Test func expiredRowsDropOutWithoutAReload() async throws {
        let fakes = FakeServices()
        let soon = fakes.clock.now.addingTimeInterval(60)
        let fixture = RootFixture(fakes: fakes)
        fixture.library.books.rows.append(Row(id: ItemID("book", "9"), title: "Library Hours", expires: soon))
        await fixture.root.ready()
        let loads = fixture.library.books.loads
        #expect(fixture.results("library hou") == ["Library Hours"])

        fixture.clock.advance(by: .seconds(61))
        #expect(fixture.results("library hou").isEmpty)
        fixture.root.end()
        await fixture.settle()
        #expect(fixture.root.row(for: ItemID("book", "9")) == nil)
        #expect(fixture.library.books.loads == loads)
        await fixture.shutdown()
    }

    @Test func directoryChangesAreReadAgain() async throws {
        let fixture = await RootFixture.ready()
        await fixture.preferences.setEnabled(true, feature: GardenFeature.manifest.id)
        await fixture.settle()
        #expect(fixture.results("water plants") == ["Water Plants"])

        fixture.preferences.setEnabled(false, command: .command(feature: "garden", command: "water"))
        await fixture.settle()
        #expect(fixture.results("water plants").isEmpty)

        await fixture.preferences.setEnabled(false, feature: LibraryFeature.manifest.id)
        await fixture.settle()
        #expect(fixture.results("example book").isEmpty)
        #expect(fixture.results("open lib").isEmpty)
        await fixture.shutdown()
    }

    @Test func kindsFollowTheNamespaceOrWhatARowStandsFor() {
        func kind(_ id: ItemID, represents: Selection? = nil) -> ItemKind {
            ItemKinds.kind(of: Row(id: id, title: "x", represents: represents))
        }
        #expect(kind(ItemID("app", "com.example.a")) == .app)
        #expect(kind(.command(feature: "a", command: "b")) == .command)
        #expect(kind(ItemID("file", "/tmp/a")) == .file)
        #expect(kind(ItemID("recent", "a"), represents: .files([URL(filePath: "/tmp/a")])) == .file)
        #expect(kind(ItemID("contacts", "a")) == .contact)
        #expect(kind(ItemID("system-settings", "a")) == .setting)
        #expect(kind(ItemID("book", "1")) == .other)
    }

    @Test func theBuilderPutsCommandsBeforeSourcesBeforeRememberedRows() {
        let shared = ItemID("book", "1")
        var inputs = CatalogInputs()
        inputs.sources = [.init(featureID: "library", rows: [Row(id: shared, title: "From Source")])]
        inputs.remembered = [(Row(id: shared, title: "From Memory"), "library")]
        let separated = Row(id: ItemID("x", "1"), title: "Bad\u{1F}Keyword", keywords: ["a\u{1F}b"])
        inputs.sources.append(.init(featureID: nil, rows: [separated]))
        let built = CatalogBuilder.build(inputs, now: Date(timeIntervalSince1970: 0))
        #expect(built.table.entry(for: shared)?.row.title == "From Source")
        #expect(built.table.entry(for: shared)?.origin == .source)
        #expect(built.items.count == 2)
        #expect(built.items.contains { $0.keywords == ["ab"] && $0.title == "BadKeyword" })
    }
}
