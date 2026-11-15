import Foundation
import Kit
import KitTesting

@testable import MenuItems

typealias Node = SimulatedMenus.Node

/// The feature over a menu reader the test builds, with an app in front.
@MainActor
struct MenuHarness {
    let harness: FeatureHarness<MenuItemsFeature>
    let menus: SimulatedMenus

    static let editor = AppInfo(bundleID: "com.example.editor", name: "Example Editor")
    static let browser = AppInfo(bundleID: "com.example.browser", name: "Example Browser")
    static let editorProcess: Int32 = 101

    init(
        apps: [SimulatedMenus.App] = [
            SimulatedMenus.App(
                bundleID: editor.bundleID, processID: editorProcess, menuBar: SimulatedMenus.sampleMenuBar)
        ],
        frontmost: AppInfo? = editor, limits: WalkLimits? = nil
    ) {
        let menus = SimulatedMenus(apps: apps)
        let fakes = FakeServices()
        fakes.override(MenuReaderKey.self, with: menus)
        fakes.workspace.frontmost = frontmost
        harness = FeatureHarness(MenuItemsFeature.self, fakes: fakes)
        if let limits { harness.feature.limits = limits }
        self.menus = menus
    }

    /// One app with this menu bar, in front.
    init(menuBar: [Node], limits: WalkLimits? = nil) {
        self.init(
            apps: [SimulatedMenus.App(bundleID: Self.editor.bundleID, processID: Self.editorProcess, menuBar: menuBar)],
            limits: limits)
    }

    var list: MenuItemList? { harness.feature.currentList }

    /// Runs Search Menu Items and waits for its read to finish and the page to show the result.
    func open() async throws {
        try await harness.run(MenuItemsFeature.searchCommandID)
        try await settled()
    }

    /// Waits until no read runs and the page shows the latest result. A read may end without a
    /// signal, when it found what the page already shows.
    func settled() async throws {
        guard let list else { return try await harness.settle() }
        repeat {
            await list.readFinished()
            try await harness.settle()
        } while list.isReading
    }

    /// Waits until the open list has handled this many closings of the launcher. The reader sends
    /// them from its own thread; the list handles them on the main actor.
    func waitForClosings(_ count: Int) async {
        guard let list else { return }
        while list.closingsHandled < count { await Task.yield() }
    }

    /// Every row, loading every page.
    func allRows() async throws -> [Row] {
        while try await harness.loadNextPage() {}
        return harness.rows
    }
}

/// Menu trees for tests, all synthetic.
enum Trees {
    static let apple = Node.menu("Apple", [.item("About This Mac"), .separator, .item("Sleep")])

    /// The Apple menu, then `menus` menus of `items` items each. Every tenth item has a shortcut.
    static func wide(menus: Int, items: Int) -> [Node] {
        [apple]
            + (1...menus).map { menu in
                Node.menu(
                    "Menu \(menu)",
                    (1...items).map { item in
                        item % 10 == 0 ? Node.item("Item \(menu).\(item)", "K") : Node.item("Item \(menu).\(item)")
                    })
            }
    }

    /// The Apple menu, then one menu whose submenus nest `levels` deep, with a leaf at every level.
    static func deep(levels: Int) -> [Node] {
        func level(_ depth: Int) -> [Node] {
            var nodes = [Node.item("Leaf \(depth)")]
            if depth < levels { nodes.append(.menu("Level \(depth + 1)", level(depth + 1))) }
            return nodes
        }
        return [apple, .menu("Deep", level(1))]
    }

    /// About `count` items in ten menus, each with submenus of 25 items, separators between groups
    /// and shortcuts on some. For budgets.
    static func large(_ count: Int) -> [Node] {
        let perMenu = count / 10
        return [apple]
            + (1...10).map { menu in
                let groups = perMenu / 25
                var nodes: [Node] = []
                for group in 1...groups {
                    let items = (1...25).map { item in
                        item == 1
                            ? Node.item("Command \(menu).\(group).\(item)", "J", modifiers: MenuShortcut.shiftBit)
                            : Node.item("Command \(menu).\(group).\(item)")
                    }
                    nodes.append(.menu("Group \(menu).\(group)", items))
                    nodes.append(.separator)
                }
                return Node.menu("Menu \(menu)", nodes)
            }
    }
}
