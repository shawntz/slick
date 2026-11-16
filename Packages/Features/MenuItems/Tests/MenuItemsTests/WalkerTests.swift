import Kit
import Testing

@testable import MenuItems

/// The walk both readers share, through the isolated reader.
@Suite("Walking a menu bar", .timeLimit(.minutes(1)))
struct WalkerTests {
    static let app = MenuApp(bundleID: "com.example.editor", name: "Example Editor")

    func reader(_ menuBar: [Node]?) -> SimulatedMenus {
        SimulatedMenus(apps: [SimulatedMenus.App(bundleID: Self.app.bundleID, processID: 7, menuBar: menuBar)])
    }

    func read(_ reader: SimulatedMenus, limits: WalkLimits = .standard) async throws -> MenuSnapshot {
        try await reader.readMenus(of: Self.app, limits: limits)
    }

    @Test func listsLeavesInMenuOrderWithTheirPaths() async throws {
        let snapshot = try await read(reader(SimulatedMenus.sampleMenuBar))
        #expect(snapshot.ending == .complete)
        #expect(snapshot.processID == 7)
        #expect(!snapshot.leftOutDeepMenus)
        let file = snapshot.items.filter { $0.menus.first == "File" }
        #expect(
            file.map(\.title) == [
                "New Document", "Open…", "Draft", "Notes", "Clear Menu", "Close Window", "Close All", "Save",
                "Save As…", "PDF…", "PNG…", "Plain Text…", "Print…",
            ])
        let png = try #require(snapshot.items.first { $0.title == "PNG…" })
        #expect(png.menus == ["File", "Export"])
        #expect(png.path.map(\.index) == [2, 8, 1], "places count separators")
        #expect(snapshot.menuTitles[0] == "Apple")
        #expect(snapshot.menuTitles[2] == "File")
        #expect(
            snapshot.items.filter(\.isInAppleMenu).map(\.title) == [
                "About This Mac", "System Settings…", "Force Quit…", "Lock Screen", "Log Out",
            ])
        #expect(!snapshot.items.contains { $0.title == "Export" || $0.title == "Open Recent" }, "menus are not items")
    }

    @Test func separatorsAndBlankTitlesAreLeftOut() async throws {
        let menuBar: [Node] = [
            Trees.apple,
            .menu(
                "File",
                [
                    .separator, .separator, .item("One"), .separator, .item("   "), .item("\n\t"), .separator,
                    .item("Two"), .separator,
                ]),
        ]
        let snapshot = try await read(reader(menuBar))
        #expect(snapshot.items.filter { !$0.isInAppleMenu }.map(\.title) == ["One", "Two"])
        #expect(snapshot.items.first { $0.title == "Two" }?.path.last?.index == 7)
    }

    @Test func titlesStayOnOneLineAndKeepEveryScript() async throws {
        let long = String(repeating: "x", count: 1_000)
        let menuBar: [Node] = [
            Trees.apple,
            .menu(
                "File",
                [
                    .item("Line one\nline two"), .item(" \u{200F}שלום "), .item("Smile 😀👍🏽 👩‍💻"), .item(long),
                    .item("Tab\there"), .item("Para\u{2029}graph"),
                ]),
        ]
        let titles = try await read(reader(menuBar)).items.filter { !$0.isInAppleMenu }.map(\.title)
        #expect(titles[0] == "Line one line two")
        #expect(titles[1] == "\u{200F}שלום")
        #expect(titles[2] == "Smile 😀👍🏽 👩‍💻", "a joined emoji keeps its joiner")
        #expect(titles[3].count == MenuWalker.titleLimit)
        #expect(titles[4] == "Tab here")
        #expect(titles[5] == "Para graph")
    }

    @Test func aWideTreeIsReadWholeAndInOrder() async throws {
        let snapshot = try await read(reader(Trees.wide(menus: 40, items: 250)))
        #expect(snapshot.ending == .complete)
        let items = snapshot.items.filter { !$0.isInAppleMenu }
        #expect(items.count == 10_000)
        #expect(items.first?.title == "Item 1.1")
        #expect(items.last?.title == "Item 40.250")
        #expect(items[9].shortcut == KeyCombo(.k, .command))
        #expect(Set(items.map { $0.ref(bundleID: "b", processID: 1).key }).count == 10_000, "every key is unique")
    }

    @Test func theItemLimitStopsAWalkAndKeepsWhatItRead() async throws {
        let snapshot = try await read(
            reader(Trees.wide(menus: 40, items: 250)), limits: WalkLimits(maximumItems: 1_000))
        #expect(snapshot.ending == .tooManyItems)
        #expect(snapshot.items.count == 1_000)
        #expect(!snapshot.isComplete)
    }

    @Test func aDeepTreeIsCutAtTheDepthLimit() async throws {
        let deep = Trees.deep(levels: 12)
        let cut = try await read(reader(deep), limits: WalkLimits(maximumDepth: 8))
        #expect(cut.leftOutDeepMenus)
        #expect(cut.ending == .complete, "a depth cut is not a failed walk")
        let leaves = cut.items.filter { !$0.isInAppleMenu }
        #expect(leaves.map(\.title) == (1...8).map { "Leaf \($0)" })
        #expect(leaves.last?.menus == ["Deep"] + (2...8).map { "Level \($0)" })

        let whole = try await read(reader(deep), limits: WalkLimits(maximumDepth: 20))
        #expect(!whole.leftOutDeepMenus)
        #expect(whole.items.filter { !$0.isInAppleMenu }.count == 12)
    }

    @Test func theSameTitleInDifferentMenusIsTwoItems() async throws {
        let menuBar: [Node] = [
            Trees.apple,
            .menu("File", [.item("Close", "W"), .item("Print…")]),
            .menu("Window", [.item("Close"), .item("Close")]),
            .menu("Format", [.menu("Font", [.item("Bigger")]), .menu("Text", [.item("Bigger")])]),
        ]
        let snapshot = try await read(reader(menuBar))
        let closes = snapshot.items.filter { $0.title == "Close" }
        #expect(closes.map(\.menus) == [["File"], ["Window"], ["Window"]])
        let keys = closes.map { $0.ref(bundleID: Self.app.bundleID, processID: 7).key }
        #expect(Set(keys).count == 3)
        #expect(keys == ["com.example.editor/1.0", "com.example.editor/2.0", "com.example.editor/2.1"])
        #expect(
            snapshot.items.filter { $0.title == "Bigger" }.map(\.menus) == [["Format", "Font"], ["Format", "Text"]])
    }

    @Test func optionAlternatesArePairedWithTheItemBefore() async throws {
        let menuBar: [Node] = [
            Trees.apple,
            .menu(
                "File",
                [
                    .item("Close Window", "W"), .item("Close All", "W", modifiers: MenuShortcut.optionBit),
                    .item("Undo", "Z"), .item("Redo", "Z", modifiers: MenuShortcut.shiftBit),
                    .item("Minimize", "M"), .separator, .item("Minimize All", "M", modifiers: MenuShortcut.optionBit),
                    .item("Find", "F"), .item("Find Again", "G", modifiers: MenuShortcut.optionBit),
                    .item("Show", "S", modifiers: MenuShortcut.optionBit),
                    .item("Show More", "S", modifiers: MenuShortcut.optionBit | MenuShortcut.shiftBit),
                    .item("Zoom"), .item("Zoom All", "Z", modifiers: MenuShortcut.optionBit),
                ]),
        ]
        let items = try await read(reader(menuBar)).items
        func alternate(of title: String) -> String? {
            items.first { $0.title == title }?.optionAlternate.map { items[$0].title }
        }
        #expect(alternate(of: "Close Window") == "Close All")
        #expect(alternate(of: "Undo") == nil, "Shift is not an Option alternate")
        #expect(alternate(of: "Minimize") == nil, "a separator lies between")
        #expect(alternate(of: "Find") == nil, "another key")
        #expect(alternate(of: "Show") == nil, "Option is already held")
        #expect(alternate(of: "Zoom") == nil, "no shortcut")
        #expect(items.contains { $0.title == "Close All" }, "the alternate is an item of its own too")
    }

    @Test func itemsUnderATurnedOffMenuAreTurnedOff() async throws {
        let menuBar: [Node] = [
            Trees.apple,
            .menu("File", [.item("Open"), .menu("Share", enabled: false, [.item("Mail"), .item("Messages")])]),
            .menu("Off", enabled: false, [.item("Inside")]),
        ]
        let items = try await read(reader(menuBar)).items
        #expect(items.first { $0.title == "Open" }?.isEnabled == true)
        #expect(items.filter { !$0.isEnabled }.map(\.title) == ["Mail", "Messages", "Inside"])
    }

    @Test func aSlowAppIsCutAtTheTimeLimit() async throws {
        let reader = reader(Trees.wide(menus: 5, items: 50))
        reader.costPerRead = .milliseconds(10)
        let snapshot = try await read(reader, limits: WalkLimits(timeLimit: .milliseconds(200)))
        #expect(snapshot.ending == .timedOut)
        #expect(reader.reads == 20, "twenty reads of 10 ms fill 200 ms")
        #expect(snapshot.items.count > 0 && snapshot.items.count < 20)
    }

    @Test func anAppThatQuitsMidWalkEndsTheWalk() async throws {
        let reader = reader(Trees.wide(menus: 5, items: 50))
        reader.quitsAfterReads = 30
        await #expect(throws: MenuReadError.appQuit) { try await read(reader) }
        await #expect(throws: MenuReadError.appNotRunning) { try await read(reader) }
        await #expect(throws: MenuReadError.appQuit) {
            try await reader.press(MenuItemRef(bundleID: Self.app.bundleID, processID: 7, path: []))
        }
    }

    @Test func missingAccessEndsTheWalk() async throws {
        let reader = reader(SimulatedMenus.sampleMenuBar)
        reader.accessGranted = false
        await #expect(throws: MenuReadError.accessMissing) { try await read(reader) }
        reader.accessGranted = true
        reader.revokesAccessAfterReads = 10
        await #expect(throws: MenuReadError.accessMissing) { try await read(reader) }
        #expect(!reader.accessGranted)
    }

    @Test func noMenuBarAndNoApp() async throws {
        await #expect(throws: MenuReadError.noMenuBar) { try await read(reader(nil)) }
        let other = MenuApp(bundleID: "com.example.missing", name: "Missing")
        await #expect(throws: MenuReadError.appNotRunning) {
            try await reader(SimulatedMenus.sampleMenuBar).readMenus(of: other, limits: .standard)
        }
    }

    @Test func anElementThatFailsIsLeftOutAndTheWalkGoesOn() async throws {
        let reader = reader(SimulatedMenus.sampleMenuBar)
        reader.failingTitles = ["Export", "Copy"]
        let snapshot = try await read(reader)
        #expect(snapshot.ending == .complete)
        #expect(!snapshot.items.contains { $0.title == "PNG…" || $0.title == "Copy" })
        #expect(snapshot.items.contains { $0.title == "Paste" })
    }

    @Test func aWalkCancelledMidwayStops() async throws {
        let reader = reader(Trees.wide(menus: 5, items: 50))
        reader.holdsAfterReads = 12
        let task = Task { try await reader.readMenus(of: Self.app, limits: .standard) }
        await reader.waitUntilHeld()
        task.cancel()
        let snapshot = try await task.value
        #expect(snapshot.ending == .stopped)
        #expect(reader.reads == 12)
        #expect(snapshot.items.count < 12)
    }

    @Test func aCancelledWalkStopsAtOnce() async throws {
        let reader = reader(Trees.wide(menus: 5, items: 50))
        let task = Task { () async throws -> MenuSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readMenus(of: Self.app, limits: .standard)
        }
        let snapshot = try await task.value
        #expect(snapshot.ending == .stopped)
        #expect(snapshot.items.isEmpty)
        #expect(reader.reads == 0)
    }

    @Test func findingAnItemAgain() async throws {
        let reader = reader(SimulatedMenus.sampleMenuBar)
        let snapshot = try await read(reader)
        let png = try #require(snapshot.items.first { $0.title == "PNG…" })
        try await reader.press(png.ref(bundleID: Self.app.bundleID, processID: 7))
        #expect(reader.presses.map(\.path.last?.title) == ["PNG…"])

        // The app added an item above: the place moved, the title still finds it.
        var moved = SimulatedMenus.sampleMenuBar
        moved[2].children[8].children.insert(.item("JPEG…"), at: 0)
        reader.setApp(SimulatedMenus.App(bundleID: Self.app.bundleID, processID: 7, menuBar: moved))
        try await reader.press(png.ref(bundleID: Self.app.bundleID, processID: 7))
        #expect(reader.presses.count == 2)

        // A key and the row's title find it by place, after checking the title there.
        let byPlace = try #require(MenuItemRef(key: "com.example.editor/2.8.2", title: "PNG…"))
        try await reader.press(byPlace)
        #expect(reader.presses.count == 3)

        // Gone, and turned off.
        moved[2].children[8].children.removeAll { $0.title == "PNG…" }
        moved[3].children[0].isEnabled = false
        reader.setApp(SimulatedMenus.App(bundleID: Self.app.bundleID, processID: 7, menuBar: moved))
        await #expect(throws: MenuReadError.itemGone) {
            try await reader.press(png.ref(bundleID: Self.app.bundleID, processID: 7))
        }
        let undo = try #require(snapshot.items.first { $0.title == "Undo" })
        await #expect(throws: MenuReadError.itemDisabled) {
            try await reader.press(undo.ref(bundleID: Self.app.bundleID, processID: 7))
        }
        #expect(reader.presses.count == 3)
    }

    @Test func rowKeysRoundTrip() throws {
        let ref = MenuItemRef(
            bundleID: "com.example.editor", processID: 9,
            path: [MenuStep(title: "File", index: 2), MenuStep(title: String(repeating: "y", count: 200), index: 11)])
        #expect(ref.key == "com.example.editor/2.11")
        #expect(ref.path[1].title.count == MenuItemRef.titleLimit)
        let parsed = try #require(MenuItemRef(key: ref.key, title: "Item"))
        #expect(parsed.bundleID == "com.example.editor")
        #expect(parsed.path.map(\.index) == [2, 11])
        #expect(parsed.path.map(\.title) == ["", "Item"])
        #expect(MenuItemRef(key: "no-slash", title: "Item") == nil)
        #expect(MenuItemRef(key: "com.example.editor/", title: "Item") == nil)
        #expect(MenuItemRef(key: "com.example.editor/1.-2", title: "Item") == nil)
        #expect(MenuItemRef(key: "com.example.editor/2.x.11", title: "Item") == nil, "every part is a place")
        #expect(MenuItemRef(key: "com.example.editor/2..11", title: "Item") == nil)
        #expect(MenuItemRef(key: "com.example.editor/2.\u{0663}", title: "Item") == nil, "ASCII digits only")
        #expect(MenuItemRef(key: "/2.11", title: "Item") == nil)
        #expect(MenuItemRef(key: ref.key, title: "") == nil, "a reference always names its item")
        #expect(MenuItemRef.matches(ref.path[1], title: String(repeating: "y", count: 200)))
    }
}
