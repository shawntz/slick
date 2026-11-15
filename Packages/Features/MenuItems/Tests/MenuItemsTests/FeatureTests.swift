import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MenuItems

@MainActor
@Suite("Menu Items feature", .timeLimit(.minutes(1)))
struct FeatureTests {
    // MARK: - Declarations

    @Test func declaresOneCommandThatNeedsAccessibility() throws {
        let menu = MenuHarness()
        let harness = menu.harness
        #expect(harness.issues.isEmpty)
        #expect(MenuItemsFeature.manifest.id == "menu-items")
        #expect(MenuItemsFeature.manifest.isEnabledByDefault)
        let need = try #require(MenuItemsFeature.manifest.permissions.first)
        #expect(MenuItemsFeature.manifest.permissions.count == 1)
        #expect(need.permission == .accessibility)
        #expect(need.reason.hasPrefix("Read "))
        let command = try harness.command("search")
        #expect(command.title == "Search Menu Items")
        #expect(command.requires == [.accessibility])
        #expect(command.suggestedHotkey == nil)
        #expect(command.arguments.isEmpty)
        #expect(command.confirmation == nil)
    }

    @Test func activationReadsNothingAndWatchesNothing() async throws {
        let menu = MenuHarness()
        await menu.harness.activate()
        try await menu.harness.settle()
        #expect(menu.menus.walks == 0)
        #expect(menu.menus.closingListenerCount == 0)
        #expect(menu.harness.fakes.permissions.requests.isEmpty)
        #expect(menu.harness.fakes.permissions.openStreamCount == 0)
        #expect(menu.harness.fakes.http.requests.isEmpty)
    }

    @Test func everyRunButTheLiveAppGetsMenusInMemory() {
        for environment in RunEnvironment.allCases where environment != .live {
            let context = FakeServices().context(featureID: "menu-items", environment: environment)
            #expect(MenuItemsFeature(context: context).reader is SimulatedMenus, "\(environment)")
        }
    }

    @Test func theScenarioSampleServesWhicheverAppIsInFront() async throws {
        let sample = SimulatedMenus.sample()
        let snapshot = try await sample.readMenus(
            of: MenuApp(bundleID: "com.example.anything", name: "Anything"), limits: .standard)
        #expect(snapshot.items.count == 45)
        #expect(snapshot.items.contains { $0.title == "Close All" })
        let save = try #require(snapshot.items.first { $0.title == "Save" })
        try await sample.press(save.ref(bundleID: "com.example.anything", processID: snapshot.processID))
        #expect(sample.presses.count == 1)
    }

    @Test func theSettingsPaneSaysWhatItKeepsAndSends() throws {
        let pane = try #require(MenuItemsFeature(context: FakeServices().context(featureID: "menu-items")).settingsPane)
        let items = pane.sections.flatMap(\.items)
        let keys = items.compactMap { $0.control.key?.name }
        #expect(keys == ["showsDisabledItems", "showsAppleMenu", "leftOutApps"])
        #expect(items.contains { if case .permission(.accessibility) = $0.control { true } else { false } })
        let notes = items.filter { if case .note = $0.control { true } else { false } }.map(\.title)
        #expect(notes.contains { $0.contains("memory") && $0.contains("never written to disk") })
        #expect(notes.contains { $0.contains("nothing over the network") })
        #expect(pane.sections.compactMap(\.title) == ["Show", "Apps", "Access", "Privacy"])
    }

    @Test func defaultsAreSafe() {
        let settings = FakeServices().context(featureID: "menu-items").settings
        #expect(settings[MenuItemsSettings.showsDisabledItems] == false)
        #expect(settings[MenuItemsSettings.showsAppleMenu] == false)
        #expect(settings[MenuItemsSettings.leftOutApps].isEmpty)
    }

    // MARK: - The list

    @Test func listsTheMenusOfTheAppInFront() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await harness.run("search")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Reading Menus")
        #expect(harness.page?.emptyState?.message == "Reading the menu bar of Example Editor.")
        if case .list(let page) = harness.page?.page {
            #expect(page.title == "Example Editor")
            #expect(page.searchPlaceholder == "Search the menus of Example Editor")
        } else {
            Issue.record("expected a list")
        }
        try await harness.waitForChange()
        #expect(menu.menus.walks == 1)
        #expect(harness.sections.map(\.title) == ["Example Editor", "File", "Edit", "View", "Window", "Help"])
        let save = try #require(harness.rows.first { $0.title == "Save" })
        #expect(save.subtitle == "File")
        #expect(save.accessories == [.shortcut(KeyCombo(.s, .command))])
        #expect(save.icon == .app(bundleID: "com.example.editor"))
        #expect(save.memory == .never)
        #expect(save.id.rawValue == "menu-items:com.example.editor/2.6")
        let png = try #require(harness.rows.first { $0.title == "PNG…" })
        #expect(png.subtitle == "File › Export")
        #expect(png.accessories.isEmpty)
        let sidebar = try #require(harness.rows.first { $0.title == "Show Sidebar" })
        #expect(sidebar.accessories.first == .icon(.symbol("checkmark"), tooltip: "Checked"))
        let fullScreen = try #require(harness.rows.first { $0.title == "Enter Full Screen" })
        #expect(fullScreen.accessories == [.shortcut(KeyCombo(.f, .function))])
        #expect(harness.page?.notice == nil)
        #expect(harness.issues.isEmpty)
    }

    @Test func turnedOffItemsAndTheAppleMenuAreHiddenUntilSettingsShowThem() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        #expect(!harness.rows.contains { $0.title == "Delete" }, "Delete is turned off")
        #expect(!harness.rows.contains { $0.title == "About This Mac" })

        harness.context.settings[MenuItemsSettings.showsDisabledItems] = true
        try await harness.settle()
        let delete = try #require(harness.rows.first { $0.title == "Delete" })
        #expect(delete.accessories == [.tag("Unavailable"), .shortcut(KeyCombo(.delete))])

        harness.context.settings[MenuItemsSettings.showsAppleMenu] = true
        try await harness.settle()
        #expect(harness.sections.first?.title == "Apple")
        #expect(harness.rows.first?.title == "About This Mac")
        #expect(menu.menus.walks == 1, "settings refilter what was read; they do not read again")
    }

    @Test func searchesTitlesAndPaths() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        try await harness.setQuery("close all")
        #expect(harness.rows.first?.title == "Close All")
        try await harness.setQuery("prin")
        #expect(harness.rows.first?.title == "Print…")
        #expect(harness.rows.first?.titleHighlights == [0..<4])
        try await harness.setQuery("export png")
        #expect(harness.rows.map(\.title) == ["PNG…"])
        try await harness.setQuery("export")
        #expect(Set(harness.rows.map(\.title)).isSuperset(of: ["PDF…", "PNG…", "Plain Text…"]))
        try await harness.setQuery("zzqx")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Matching Menu Items")
        try await harness.setQuery("about this mac")
        #expect(harness.rows.isEmpty, "the Apple menu stays hidden while searching")
        #expect(MenuRows.searchesOnMainThread.load(ordering: .relaxed) == 0)
        let read = try #require(harness.feature.cache.entry(for: "com.example.editor")?.snapshot.items.count)
        #expect(harness.fakes.fuzzyIndex.builtIndexSizes == [read], "indexed once, with every item")
    }

    @Test func anEmptyMenuBarAndOneWhollyHidden() async throws {
        let empty = MenuHarness(menuBar: [])
        try await empty.open()
        #expect(empty.harness.page?.emptyState?.title == "No Menu Items")
        #expect(empty.harness.page?.emptyState?.message == "Example Editor shows no menu items.")

        let hidden = MenuHarness(menuBar: [Trees.apple, .menu("File", [.item("Off", enabled: false)])])
        try await hidden.open()
        #expect(hidden.harness.rows.isEmpty)
        #expect(hidden.harness.page?.emptyState?.message?.contains("You can show those in settings") == true)
    }

    // MARK: - Running an item

    @Test func returnClosesTheLauncherThenTheAppComesForwardThenTheItemIsPressed() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        let closedWhenPressed = Recorded<Bool>()
        menu.menus.onPress = { _ in
            await closedWhenPressed.set(await MainActor.run { harness.isClosed })
        }
        try harness.select(title: "Save")
        #expect(harness.actions().map(\.id) == ["run", "read-again"])
        let run = try #require(harness.actions().first)
        #expect(run.title == "Run Menu Item")
        #expect(run.requires == [.accessibility])
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .close(hud: nil))
        #expect(harness.isClosed)
        #expect(await closedWhenPressed.value == true)
        #expect(menu.menus.activations == ["com.example.editor"])
        #expect(menu.menus.frontmost == "com.example.editor")
        let pressed = try #require(menu.menus.presses.first)
        #expect(pressed.path.map(\.title) == ["File", "Save"])
        #expect(pressed.processID == MenuHarness.editorProcess)
        #expect(harness.huds.isEmpty)
        #expect(harness.issues.isEmpty)
    }

    @Test func optionReturnRunsTheOptionAlternate() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        try harness.select(title: "Close Window")
        let row = try #require(harness.selectedRow)
        #expect(row.alternates == [Row.Alternate(modifiers: .option, subtitle: "Return runs “Close All”.")])
        let alternate = try #require(harness.actions().first { $0.id == "run-option-alternate" })
        #expect(alternate.title == "Run “Close All”")
        #expect(alternate.shortcut == KeyCombo(.return, .option))
        try await harness.perform("run-option-alternate")
        #expect(menu.menus.presses.map(\.path.last?.title) == ["Close All"])
        #expect(harness.isClosed)

        try harness.select(title: "Save")
        #expect(!harness.actions().contains { $0.id == "run-option-alternate" })
    }

    @Test func aTurnedOffItemSaysSoAndStaysOpen() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        harness.context.settings[MenuItemsSettings.showsDisabledItems] = true
        try await menu.open()
        try harness.select(title: "Delete")
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .keepOpen)
        #expect(!harness.isClosed)
        #expect(harness.visibleToast?.title == "Menu Item Unavailable")
        #expect(menu.menus.presses.isEmpty)
    }

    @Test func pressFailuresShowWhatHappenedAfterTheLauncherClosed() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        harness.throwsActionErrors = false
        try await menu.open()

        // The app rebuilt its File menu without Save.
        var changed = SimulatedMenus.sampleMenuBar
        changed[2].children.removeAll { $0.title == "Save" }
        menu.menus.setApp(
            SimulatedMenus.App(bundleID: "com.example.editor", processID: MenuHarness.editorProcess, menuBar: changed))
        try harness.select(title: "Save")
        try await harness.performPrimary()
        #expect(harness.huds.last == .failure("Could Not Run “Save”"))
        let gone = try #require(harness.actionErrors.last as? ActionFailure)
        #expect(gone.message?.hasPrefix("Example Editor no longer shows this menu item") == true)
        try await menu.settled()
        #expect(!harness.rows.contains { $0.title == "Save" }, "the next showing read the menus again")

        // The app quit.
        menu.menus.removeApp("com.example.editor")
        try harness.select(title: "Print…")
        try await harness.performPrimary()
        #expect(harness.huds.last == .failure("Could Not Run “Print…”"))
        #expect((harness.actionErrors.last as? ActionFailure)?.message == "Example Editor is no longer open.")

        // The list now says the app is not open.
        try await menu.settled()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Example Editor Is Not Open")

        // Access went away after the host checked it.
        menu.menus.setApp(
            SimulatedMenus.App(
                bundleID: "com.example.editor", processID: MenuHarness.editorProcess,
                menuBar: SimulatedMenus.sampleMenuBar))
        harness.pop()
        try await menu.open()
        menu.menus.accessGranted = false
        try harness.select(title: "Copy")
        try await harness.performPrimary()
        #expect(harness.huds.last == .failure("Menu Search Needs Accessibility"))
        #expect(menu.menus.presses.isEmpty)
    }

    @Test func readMenusAgainReadsAfreshAndShowsProgress() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        var changed = SimulatedMenus.sampleMenuBar
        changed[5].children.append(.item("Show Status Bar", "/"))
        menu.menus.setApp(
            SimulatedMenus.App(bundleID: "com.example.editor", processID: MenuHarness.editorProcess, menuBar: changed))
        try harness.select(title: "Save")
        let action = try #require(harness.actions().first { $0.id == "read-again" })
        #expect(action.title == "Read Menus Again")
        #expect(action.shortcut == .refresh)
        let outcome = try await harness.perform("read-again")
        #expect(outcome.kind == .keepOpen)
        #expect(harness.toasts.last?.title == "Reading Menus")
        #expect(harness.toasts.last?.style == .progress)
        try await menu.settled()
        #expect(menu.menus.walks == 2)
        #expect(harness.rows.contains { $0.title == "Show Status Bar" })
        #expect(harness.visibleToast == nil, "the progress toast goes when the read ends")
        #expect(harness.issues.isEmpty)
    }

    @Test func actionsWorkFromTheRowIDAlone() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        let save = try #require(harness.rows.first { $0.title == "Save" })
        let rebuilt = Row(id: save.id, title: save.title)
        let list = try #require(menu.list)
        let actions = list.actions(for: rebuilt)
        #expect(actions.map(\.id) == ["run", "read-again"])
        try await harness.perform(try #require(actions.first), row: rebuilt)
        #expect(menu.menus.presses.first?.path.map(\.index) == [2, 6])
        let payload = try #require(save.payload)
        let encoded = try JSONEncoder().encode(payload)
        #expect(encoded.count < 1_024)
    }

    // MARK: - Which app

    @Test func noAppInFrontOrTheLauncherItself() async throws {
        let none = MenuHarness(frontmost: nil)
        let outcome = try await none.harness.run("search")
        #expect(outcome.kind == .keepOpen)
        #expect(none.harness.visibleToast?.title == "No App to Search")
        #expect(none.harness.pages.isEmpty)

        let itself = MenuHarness(frontmost: AppInfo(bundleID: Brand.bundleID, name: Brand.name))
        try await itself.harness.run("search")
        #expect(itself.harness.visibleToast?.title == "No App to Search")
        #expect(none.menus.walks == 0 && itself.menus.walks == 0)
    }

    @Test func appsLeftOutAreNeverRead() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        harness.context.settings[MenuItemsSettings.leftOutApps] = ["com.example.editor"]
        let outcome = try await harness.run("search")
        #expect(outcome.kind == .keepOpen)
        #expect(harness.visibleToast?.title == "Example Editor Is Left Out")
        #expect(menu.menus.walks == 0)

        // Left out while its list is open.
        harness.context.settings[MenuItemsSettings.leftOutApps] = []
        try await menu.open()
        #expect(!harness.rows.isEmpty)
        harness.context.settings[MenuItemsSettings.leftOutApps] = ["com.example.other", "com.example.editor"]
        try await harness.settle()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Example Editor Is Left Out")
        #expect(harness.feature.cache.count == 0, "its menus are forgotten")
        #expect(menu.menus.walks == 1)
    }

    @Test func aPageLeftOpenFollowsTheAppInFrontTheNextTime() async throws {
        let menu = MenuHarness(apps: [
            SimulatedMenus.App(
                bundleID: MenuHarness.editor.bundleID, processID: 101, menuBar: SimulatedMenus.sampleMenuBar),
            SimulatedMenus.App(
                bundleID: MenuHarness.browser.bundleID, processID: 202,
                menuBar: [Trees.apple, .menu("History", [.item("Show All History", "Y")])]),
        ])
        let harness = menu.harness
        try await menu.open()
        #expect(harness.rows.contains { $0.title == "Save" })

        // The launcher closes; the next summon comes from the browser and shows the same page.
        harness.fakes.workspace.frontmost = MenuHarness.browser
        menu.menus.simulateLauncherClosing()
        try await harness.waitForChange()
        #expect(menu.list?.target == .app(MenuApp(bundleID: "com.example.browser", name: "Example Browser")))
        if harness.rows.isEmpty { try await harness.waitForChange() }
        #expect(harness.rows.map(\.title) == ["Show All History"])
        #expect(harness.rows.first?.subtitle == "History")
    }

    // MARK: - When reading goes wrong

    @Test func missingAccessShowsTheGrantCardFromAButton() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        menu.menus.accessGranted = false
        try await menu.open()
        #expect(harness.page?.emptyState?.title == "Menu Search Needs Accessibility")
        let grant = try #require(harness.page?.emptyState?.actions.first)
        #expect(grant.title == "Grant Access")
        #expect(grant.requires == [.accessibility])
        #expect(harness.fakes.permissions.requests.isEmpty, "nothing asked before the button")

        menu.menus.accessGranted = true
        try await harness.perform("grant-access")
        try await harness.waitForChange()
        if harness.rows.isEmpty { try await harness.waitForChange() }
        #expect(harness.rows.contains { $0.title == "Save" })
        #expect(harness.issues.isEmpty)
    }

    @Test func anAppThatQuitsMidReadSaysSo() async throws {
        let menu = MenuHarness()
        menu.menus.quitsAfterReads = 20
        try await menu.open()
        #expect(menu.harness.rows.isEmpty)
        #expect(menu.harness.page?.emptyState?.title == "Example Editor Is Not Open")
        #expect(menu.harness.feature.cache.count == 0)
    }

    @Test func anAppWithNoMenuBar() async throws {
        let menu = MenuHarness(menuBar: [])
        menu.menus.setApp(SimulatedMenus.App(bundleID: "com.example.editor", processID: 101, menuBar: nil))
        try await menu.open()
        #expect(menu.harness.page?.emptyState?.title == "No Menu Bar")
    }

    @Test func aSlowAppShowsWhatWasReadWithANotice() async throws {
        let menu = MenuHarness(limits: WalkLimits(timeLimit: .milliseconds(300)))
        menu.menus.costPerRead = .milliseconds(10)
        try await menu.open()
        #expect(!menu.harness.rows.isEmpty)
        let notice = try #require(menu.harness.page?.notice)
        #expect(notice.title == "Some Menu Items Are Missing")
        #expect(
            notice.message == "Example Editor answered slowly, so the list stops at what it read in 300 milliseconds.")
        #expect(notice.action?.title == "Read Menus Again")
        #expect(notice.action?.shortcut == .refresh)
    }

    @Test func aHugeMenuIsCutAtTheItemLimitWithANotice() async throws {
        let menu = MenuHarness(menuBar: Trees.wide(menus: 4, items: 300), limits: WalkLimits(maximumItems: 1_000))
        try await menu.open()
        #expect(try await menu.allRows().count == 998, "the Apple menu's two items count toward the limit")
        #expect(menu.harness.page?.notice?.message == "The list stops at 1000 menu items.")
    }

    @Test func deepMenusLeftOutAreNoted() async throws {
        let menu = MenuHarness(menuBar: Trees.deep(levels: 10), limits: WalkLimits(maximumDepth: 4))
        try await menu.open()
        #expect(menu.harness.rows.map(\.title) == ["Leaf 1", "Leaf 2", "Leaf 3", "Leaf 4"])
        #expect(menu.harness.page?.notice?.message == "Menus nested more than 4 levels deep are left out.")
    }

    // MARK: - The cache

    @Test func theSecondOpeningShowsAtOnceAndRefreshesBehind() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        harness.pop()

        // The app added an item since.
        var changed = SimulatedMenus.sampleMenuBar
        changed[2].children.insert(.item("Duplicate", "D", modifiers: MenuShortcut.shiftBit), at: 7)
        menu.menus.setApp(
            SimulatedMenus.App(bundleID: "com.example.editor", processID: MenuHarness.editorProcess, menuBar: changed))

        try await harness.run("search")
        #expect(harness.rows.contains { $0.title == "Save" }, "the cached menus show on the first load")
        #expect(!harness.rows.contains { $0.title == "Duplicate" })
        try await harness.waitForChange()
        #expect(menu.menus.walks == 2)
        #expect(harness.rows.contains { $0.title == "Duplicate" })
    }

    @Test func anUnchangedRefreshDoesNotReloadThePage() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        harness.pop()
        try await harness.run("search")
        let list = try #require(menu.list)
        let generation = list.changes?.generation
        #expect(list.isReading)
        await list.readFinished()
        #expect(menu.menus.walks == 2)
        #expect(list.changes?.generation == generation)
    }

    @Test func theLauncherClosingStopsTheReadAndTheNextShowingReadsAgain() async throws {
        let menu = MenuHarness(menuBar: Trees.wide(menus: 5, items: 40))
        let harness = menu.harness
        menu.menus.closesLauncherAfterReads = 30
        try await harness.run("search")
        let list = try #require(menu.list)
        await list.readFinished()
        await menu.waitForClosings(1)
        #expect(menu.menus.reads == 30, "the read stopped when the launcher closed")
        #expect(menu.menus.walks == 1, "the closing itself starts no read")

        // The load the host makes when the page shows again shows what was read, and reads afresh.
        try await harness.settle()
        let partial = harness.rows.count
        #expect(partial > 0 && partial < 30)
        #expect(harness.page?.notice == nil)
        #expect(list.isReading)
        try await menu.settled()
        #expect(menu.menus.walks == 2)
        #expect(try await menu.allRows().count == 200)
    }

    @Test func aClosingWhileThePageIsIdleMakesTheNextShowingReadAgain() async throws {
        let menu = MenuHarness()
        let harness = menu.harness
        try await menu.open()
        let list = try #require(menu.list)
        #expect(menu.menus.walks == 1)
        menu.menus.simulateLauncherClosing()
        try await harness.waitForChange()
        #expect(list.isReading)
        #expect(!harness.rows.isEmpty, "the cached rows show while the fresh read runs")

        // A closing during a read stops it and starts nothing itself.
        list.launcherClosed()
        list.launcherClosed()
        await list.readFinished()
        #expect(menu.menus.walks == 2)
        #expect(!list.isReading)
    }

    @Test func theCacheKeepsAFewAppsAndPrefersCompleteReads() {
        let cache = MenuCache()
        let fuzzy = FakeFuzzyIndexService()
        func snapshot(_ id: Int, ending: WalkEnding = .complete, items: Int = 1) -> MenuSnapshot {
            MenuSnapshot(
                app: MenuApp(bundleID: "com.example.app\(id)", name: "App \(id)"), processID: Int32(id),
                items: (0..<items).map {
                    MenuItem(
                        path: [MenuStep(title: "I\($0)", index: $0)], isEnabled: true, mark: "", isInAppleMenu: false)
                },
                menuTitles: [:], ending: ending, leftOutDeepMenus: false)
        }
        for id in 1...(MenuCache.capacity + 1) { cache.store(snapshot(id), fuzzy: fuzzy) }
        #expect(cache.count == MenuCache.capacity)
        #expect(cache.entry(for: "com.example.app1") == nil, "the one used longest ago went")
        #expect(cache.entry(for: "com.example.app2") != nil)

        #expect(
            !cache.store(snapshot(2, ending: .timedOut, items: 5), fuzzy: fuzzy),
            "a partial read never replaces a whole one")
        #expect(cache.entry(for: "com.example.app2")?.snapshot.items.count == 1)
        #expect(cache.store(snapshot(2, items: 3), fuzzy: fuzzy))
        let generation = try? #require(cache.entry(for: "com.example.app2")?.generation)
        #expect(!cache.store(snapshot(2, items: 3), fuzzy: fuzzy, unchangedSince: generation))
        cache.remove("com.example.app2")
        #expect(cache.entry(for: "com.example.app2") == nil)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func turningTheFeatureOffForgetsEverythingAndStopsTheRead() async throws {
        let menu = MenuHarness()
        try await menu.open()
        #expect(menu.harness.feature.cache.count == 1)
        await menu.harness.deactivate()
        #expect(menu.harness.feature.cache.count == 0)
        #expect(menu.list == nil)
    }

    @Test func aClosedPageLetsGoOfItsReadAndItsWatch() async throws {
        let menu = MenuHarness()
        try await menu.open()
        weak let list = menu.list
        #expect(list != nil)
        #expect(menu.menus.closingListenerCount == 1)
        menu.harness.pop()
        await menu.harness.deactivate()
        #expect(list == nil, "nothing keeps the page's source alive")
    }

    // MARK: - Paging

    @Test func longMenusArriveAPageAtATime() async throws {
        let menu = MenuHarness(menuBar: Trees.wide(menus: 10, items: 100))
        let harness = menu.harness
        try await menu.open()
        #expect(harness.rows.count == MenuRows.pageSize)
        #expect(harness.page?.nextPage != nil)
        let all = try await menu.allRows()
        #expect(all.count == 1_000)
        #expect(all.last?.title == "Item 10.100")
        #expect(harness.sections.count == 10, "pages join their menu's section")
    }
}

/// A value a background closure records for the test to read.
actor Recorded<Value: Sendable> {
    private(set) var value: Value?

    func set(_ value: Value) {
        self.value = value
    }
}
