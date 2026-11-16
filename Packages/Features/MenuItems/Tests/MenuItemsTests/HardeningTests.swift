import Foundation
import Kit
import KitTesting
import Testing

@testable import MenuItems

/// What a second review found: a press must only ever act on the item the row showed, a slow app
/// must not hold a press, no row may have a title nobody can see, and left-out apps compare as
/// macOS compares bundle IDs.
@Suite("Hardening", .timeLimit(.minutes(1)))
@MainActor
struct HardeningTests {
    static let app = MenuApp(bundleID: "com.example.editor", name: "Example Editor")

    /// The sample menu bar with an item put into File at a place.
    private func fileMenu(inserting node: Node, at place: Int) -> [Node] {
        var bar = SimulatedMenus.sampleMenuBar
        bar[2].children.insert(node, at: place)
        return bar
    }

    // MARK: - Pressing only what the row showed

    @Test func aRowRebuiltFromItsIDNeverPressesWhatMovedIntoItsPlace() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        harness.throwsActionErrors = false
        try await menu.open()
        let save = try #require(harness.rows.first { $0.title == "Save" })
        #expect(save.id.key == "com.example.editor/2.6")
        let rebuilt = Row(id: save.id, title: save.title)
        let list = try #require(menu.list)

        // Another item now sits where Save was: the press finds Save by its title further down.
        menu.menus.setApp(
            SimulatedMenus.App(
                bundleID: MenuHarness.editor.bundleID, processID: MenuHarness.editorProcess,
                menuBar: fileMenu(inserting: .item("Delete Everything"), at: 6)))
        try await harness.perform(try #require(list.actions(for: rebuilt).first), row: rebuilt)
        #expect(menu.menus.presses.last?.path.last?.title == "Save")

        // Save is gone: nothing is pressed, although an item sits at its old place.
        var withoutSave = fileMenu(inserting: .item("Delete Everything"), at: 6)
        withoutSave[2].children.removeAll { $0.title == "Save" }
        menu.menus.setApp(
            SimulatedMenus.App(
                bundleID: MenuHarness.editor.bundleID, processID: MenuHarness.editorProcess, menuBar: withoutSave))
        let pressed = menu.menus.presses.count
        try await harness.perform(try #require(list.actions(for: rebuilt).first), row: rebuilt)
        #expect(menu.menus.presses.count == pressed)
        #expect(harness.huds.last == .failure("Could Not Run “Save”"))
    }

    @Test func aRowWithNoTitleOrADamagedIDOffersNoPress() async throws {
        let menu = MenuHarness()
        try await menu.open()
        let list = try #require(menu.list)
        let untitled = Row(id: ItemID(MenuRows.namespace, "com.example.editor/2.6"), title: "\u{200B}")
        #expect(list.actions(for: untitled).map(\.id) == ["read-again"])
        let damaged = Row(id: ItemID(MenuRows.namespace, "com.example.editor/2.x.6"), title: "Save")
        #expect(list.actions(for: damaged).map(\.id) == ["read-again"])
    }

    @Test func aSlowAppCannotHoldAPressForLong() async throws {
        // Fifty items before Save, and Save no longer at its place: finding it means reading on.
        var bar = SimulatedMenus.sampleMenuBar
        bar[2].children.insert(contentsOf: (1...50).map { Node.item("Filler \($0)") }, at: 0)
        let reader = SimulatedMenus(
            apps: [SimulatedMenus.App(bundleID: Self.app.bundleID, processID: 7, menuBar: bar)])
        let save = MenuItemRef(
            bundleID: Self.app.bundleID, processID: 7,
            path: [MenuStep(title: "File", index: 2), MenuStep(title: "Save", index: 6)])

        reader.costPerRead = .milliseconds(100)
        await #expect(throws: MenuReadError.notAnswering) { try await reader.press(save) }
        #expect(reader.presses.isEmpty)
        #expect(reader.reads <= 32, "it stopped near the 3 second limit, not after every item")

        reader.costPerRead = .zero
        try await reader.press(save)
        #expect(reader.presses.map(\.path.last?.title) == ["Save"])
    }

    // MARK: - Titles nobody can see

    @Test func titlesMadeOnlyOfInvisibleCharactersAreLeftOut() async throws {
        let bar: [Node] = [
            Trees.apple,
            .menu(
                "Odd",
                [
                    .item("\u{200B}"), .item("\u{2060}\u{FEFF}"), .item(" \u{200E} "), .item("\u{202E}"),
                    .item("A\u{200B}B"), .item("👩‍💻 Code"), .item("שמור"), .item("\u{202E}evaS"),
                ]),
        ]
        let reader = SimulatedMenus(
            apps: [SimulatedMenus.App(bundleID: Self.app.bundleID, processID: 7, menuBar: bar)])
        let snapshot = try await reader.readMenus(of: Self.app, limits: .standard)
        let odd = snapshot.items.filter { $0.menus == ["Odd"] }.map(\.title)
        #expect(odd == ["A\u{200B}B", "👩‍💻 Code", "שמור", "\u{202E}evaS"])
        #expect(odd.allSatisfy { !$0.isEmpty })
        #expect(MenuWalker.cleanTitle("\u{200B}\n\u{200B}") == "")
    }

    // MARK: - Left-out apps

    @Test func leftOutAppsCompareWithoutCaseOrOuterSpaces() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        harness.context.settings[MenuItemsSettings.leftOutApps] = [" COM.Example.Editor "]
        let outcome = try await harness.run("search")
        #expect(outcome.kind == .keepOpen)
        #expect(harness.visibleToast?.title == "Example Editor Is Left Out")
        #expect(menu.menus.walks == 0)

        let itself = MenuHarness(frontmost: AppInfo(bundleID: Brand.bundleID.uppercased(), name: Brand.name))
        _ = try await itself.harness.run("search")
        #expect(itself.harness.visibleToast?.title == "No App to Search")
        #expect(itself.menus.walks == 0)
    }

    // MARK: - Off and on

    @Test func switchingOffAndOnReadsNothingUntilTheCommandRuns() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        let walks = menu.menus.walks
        for _ in 0..<3 {
            await harness.deactivate()
            await harness.activate()
        }
        try await harness.settle()
        #expect(menu.menus.walks == walks)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        try await menu.open()
        #expect(menu.menus.walks == walks + 1, "the cache went with the feature, so the menus are read again")
    }
}
