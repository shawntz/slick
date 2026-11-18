import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Root search in the panel, driven through the keyboard's entry points.
@Suite("Panel: root search", .serialized, .timeLimit(.minutes(1)))
@MainActor struct RootPanelTests {
    @Test func eachKeystrokeUpdatesRootAndDrawsTheSnapshot() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        #expect(fixture.root.calls.first == .begin)
        #expect(fixture.rootTitles == SampleRows.all.map(\.title))
        fixture.type("ec")
        #expect(fixture.root.calls.last == .update("ec"))
        #expect(fixture.rootTitles == ["Echo"])
        let row = fixture.panel.rootPage.list.content.sections[0].rows[0]
        #expect(row.titleHighlights == [HighlightRange(location: 0, length: 2)])
        #expect(row.id == SampleRows.echo.id.engineKey)
        #expect(fixture.panel.rootPage.list.selectedRow == 0)
        #expect(fixture.field.ghostText == "", "argument chips hide the ghost")
        fixture.type("Ex")
        #expect(fixture.field.ghostText == "ample Editor")
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Open")
    }

    @Test func accessoriesMapToTheListsKinds() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Notes")
        let row = fixture.panel.rootPage.list.content.sections[0].rows[0]
        #expect(row.accessories == [.tag("Text", color: ThemeColor(.blue)), .keycaps(["⌘", "N"])])
        #expect(row.subtitle == "~/example")
    }

    @Test func aLateSectionKeepsTheSelectionOnTheSameRow() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        fixture.press(.moveDown)
        let selected = fixture.panel.rootPage.selectedRow?.row.id
        #expect(selected == fixture.root.snapshot.rows[1].id)
        let late = RootSection(
            id: "late", title: "From the Web", rows: [Row(id: ItemID("web", "1"), title: "Elsewhere")],
            kind: .provider(namespace: "web"))
        fixture.root.simulateLateSection(late)
        #expect(await waitUntil { fixture.panel.rootPage.list.content.sections.count == 2 })
        #expect(fixture.panel.rootPage.selectedRow?.row.id == selected)
    }

    /// Root replaces an answer in place when it changes, as a calculation does when its rates
    /// arrive. The row keeps its ID, so the selection stays on it, and the bar names its new action.
    @Test(arguments: [0, 2])
    func aRowReplacedInPlaceKeepsTheSelection(selectedIndex: Int) async throws {
        _ = NSApplication.shared
        let runtime = RuntimeFixture()
        await runtime.start()
        let root = AnswerRoot()
        let surface = LauncherSurface(visibleFrame: PanelFixture.offscreen)
        let panel = PanelController(
            runtime: runtime.runtime, rootSource: root, icons: FakeIconProvider(), surface: surface,
            hud: RecordingHUD())
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        defer { surface.panel.close() }
        panel.prewarm()
        panel.summon()
        surface.queryField.text = "10 usd"
        panel.queryField(surface.queryField, didChangeText: "10 usd")
        for _ in 0..<selectedIndex { _ = panel.queryField(surface.queryField, perform: .moveDown) }
        let selected = try #require(panel.rootPage.selectedRow?.row)
        #expect(panel.surface.actionBar.content.primaryTitle == "Copy " + selected.title)

        root.answer("9.21 EUR")
        #expect(await waitUntil { panel.rootPage.list.content.sections.first?.rows.first?.title == "9.21 EUR" })
        #expect(panel.rootPage.list.selectedRow == selectedIndex)
        #expect(panel.rootPage.selectedRow?.row.id == selected.id)
        let now = try #require(panel.rootPage.selectedRow?.row)
        #expect(panel.surface.actionBar.content.primaryTitle == "Copy " + now.title)
    }

    @Test func returnRunsTheRowWithItsSectionsLaunchAndReportsItFirst() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.press(.moveDown)
        #expect(fixture.panel.rootPage.selectedRow?.row.id == SampleRows.plain.id)
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.runtime.workbench.log == ["plain"] })
        #expect(fixture.runtime.workbench.launches == [.suggestion])
        #expect(await waitUntil { !fixture.panel.isPanelVisible })
        let calls = fixture.root.calls
        let ran = calls.firstIndex(of: .didRun(SampleRows.plain.id, .suggestion))
        let ended = calls.lastIndex(of: .end)
        #expect(ran != nil && ended != nil && ran! < ended!, "didRun comes before end()")
        #expect(fixture.hud.shown == ["Done"])
    }

    /// The action bar names the primary entry on every keystroke without building the row's
    /// entries: Run Command for a command, and Root's actions once while the same row stays on top.
    @Test func typingNamesThePrimaryEntryWithoutBuildingTheRowsEntries() async throws {
        let fixture = await PanelFixture.make(rows: SampleRows.all + [SampleRows.toolkit])
        defer { fixture.close() }
        let asked = Box(0)
        let actions = fixture.root.rowActions
        fixture.root.rowActions = { row in
            asked.value += 1
            return actions(row)
        }
        let builds = fixture.runtime.workbench.rowActionBuilds
        for text in ["T", "To", "Too", "Tool"] { fixture.type(text) }
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Run Command")
        #expect(fixture.panel.surface.actionBar.content.actionsTitle == "Actions")
        #expect(fixture.runtime.workbench.rowActionBuilds == builds, "typing builds no row actions")
        fixture.command("k")
        #expect(fixture.runtime.workbench.rowActionBuilds > builds, "the action panel builds them")
        fixture.command("k")

        for text in ["Ex", "Exa", "Exam", "Examp"] { fixture.type(text) }
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Open")
        #expect(asked.value == 1, "the same row on top asks Root once")
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.opened.value == [SampleRows.editor.id] })
        fixture.type("zzz")
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == nil)
        #expect(fixture.panel.surface.actionBar.content.actionsTitle == nil)
    }

    @Test func commandDigitsRunTheNthRow() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        let third = fixture.root.snapshot.rows[2]
        #expect(fixture.command("3"))
        #expect(await waitUntil { fixture.opened.value == [third.id] })
        #expect(fixture.root.calls.contains(.didRun(third.id, .root)))
    }

    @Test func aCommandWithArgumentsShowsChipsAndNeedsItsRequiredOne() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Echo")
        #expect(fixture.field.arguments.map(\.placeholder) == ["text", "mode"])
        #expect(fixture.field.arguments.map(\.value) == ["", "plain"])
        fixture.press(.submit([]))
        #expect(fixture.runtime.workbench.log.isEmpty, "the required argument is empty")
        fixture.field.arguments = [
            QueryArgument(placeholder: "text", value: "hello"), QueryArgument(placeholder: "mode", value: "plain"),
        ]
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.runtime.workbench.log == ["echo"] })
        #expect(fixture.runtime.workbench.arguments == [CommandArguments(["text": "hello", "mode": "plain"])])
        #expect(fixture.runtime.workbench.launches == [.root])
        fixture.type("Plain")
        #expect(fixture.field.arguments.isEmpty)
    }

    @Test func tabAcceptsTheCompletionOrRunsTheTabCommand() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.root.tabCommand = .command(feature: "relay", command: "receive")
        fixture.type("ex")
        #expect(fixture.press(.complete))
        #expect(fixture.field.text == "example Editor")
        #expect(fixture.root.calls.last == .update("example Editor"))
        fixture.type("zzz")
        fixture.press(.complete)
        #expect(await waitUntil { fixture.runtime.relay.received == [CommandArguments(["text": "zzz"])] })
        #expect(fixture.runtime.relay.launches == [.tabFromRoot])
    }

    @Test func aFallbackRunsWithTheTypedText() async {
        let fixture = await PanelFixture.make(fallbacks: [SampleRows.search])
        defer { fixture.close() }
        fixture.type("zzz")
        #expect(fixture.panel.rootPage.selectedRow?.kind == .fallbacks)
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.runtime.relay.received == [CommandArguments(["text": "zzz"])] })
        #expect(fixture.runtime.relay.launches == [.fallback])
        #expect(fixture.root.calls.contains(.didRun(SampleRows.search.id, .fallback)))
    }

    @Test func escapeClearsThenGoesBackThenDismisses() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        fixture.press(.cancel([]))
        #expect(fixture.field.text.isEmpty)
        #expect(fixture.root.calls.last == .update(""))
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("form"), launch: .root)
        #expect(await waitUntil { fixture.panel.stack.count == 2 })
        #expect(fixture.panel.top is FormPageController)
        #expect(fixture.panel.surface.queryField.leading == QueryLeading(glyph: .back, breadcrumb: "New Item"))
        fixture.press(.cancel([]))
        #expect(fixture.panel.stack.count == 1)
        fixture.press(.cancel([]))
        #expect(!fixture.panel.isPanelVisible)
    }

    @Test func lateIconsFillInWithoutWaiting() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        fixture.icons.holdBack(.symbol("circle"))
        fixture.panel.summon()
        fixture.type("Plain")
        #expect(fixture.panel.rootPage.list.content.sections[0].rows[0].icon == nil)
        fixture.icons.deliverHeldIcons()
        #expect(await waitUntil { fixture.panel.rootPage.list.content.sections[0].rows[0].icon != nil })
    }

    @Test func quickLookOpensTheRowsFile() async {
        let url = URL(filePath: "/tmp/example/preview.txt")
        let row = Row(id: ItemID("file", url.path), title: "Preview", quickLookURL: url)
        let fixture = await PanelFixture.make(rows: [row])
        defer { fixture.close() }
        let looked = Box<[[URL]]>([])
        fixture.panel.onQuickLook = { looked.value.append($0) }
        #expect(fixture.command("y"))
        #expect(looked.value == [[url]])
    }
}

/// Summon, dismiss and returning to root.
@Suite("Panel: summon", .serialized, .timeLimit(.minutes(1)))
@MainActor struct SummonTests {
    @Test func summonBeginsAndDismissEndsTheSession() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let before = fixture.root.calls.count
        fixture.panel.summon()
        #expect(fixture.panel.isPanelVisible)
        #expect(fixture.root.calls[before...].elementsEqual([.begin]))
        fixture.type("e")
        fixture.panel.dismiss()
        #expect(fixture.root.calls.last == .end)
        #expect(!fixture.panel.isPanelVisible)
    }

    /// A Return while a late section still loads closes the panel. Ending the session cancels that
    /// section, so the hidden page is no longer busy and the loading bar is off; the next summon
    /// with the query still typed starts the section again.
    @Test func dismissWhileASectionLoadsLeavesThePageIdle() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.root.marksQueriesLoading = true
        fixture.type("e")
        #expect(fixture.panel.rootPage.isBusy)
        #expect(fixture.panel.surface.isLoading)
        fixture.panel.dismiss()
        #expect(fixture.root.calls.last == .end)
        #expect(!fixture.panel.rootPage.isBusy)
        #expect(!fixture.panel.surface.isLoading)
        fixture.panel.summon()
        #expect(fixture.root.calls.last == .update("e"))
        #expect(fixture.panel.rootPage.isBusy)
    }

    @Test func zeroResetsToRootAtOnce() async {
        let fixture = await PanelFixture.make(settings: ["resetToRootAfter": .int(0)])
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root)
        #expect(await waitUntil { fixture.panel.stack.count == 2 })
        fixture.panel.dismiss()
        #expect(fixture.panel.stack.count == 1)
        #expect(fixture.field.text.isEmpty)
    }

    @Test func thePanelReturnsToRootAfterTheDelay() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root)
        #expect(await waitUntil { fixture.panel.stack.count == 2 })
        fixture.panel.dismiss()
        #expect(fixture.panel.stack.count == 2, "within the delay the page stays")
        await fixture.runtime.fakes.clock.waitForSleepers(1)
        fixture.runtime.fakes.clock.advance(by: .seconds(90))
        #expect(await waitUntil { fixture.panel.stack.count == 1 })
    }

    @Test func aRunThatClosesThePanelClearsTheQueryAtOnce() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        fixture.press(.submit([]))
        #expect(await waitUntil { !fixture.opened.value.isEmpty })
        #expect(!fixture.panel.isPanelVisible)
        #expect(fixture.field.text.isEmpty, "the next summon starts empty, not 90 seconds later")
        #expect(fixture.panel.stack.count == 1)
    }

    /// An opened app takes the keyboard, and the panel closes before the open action returns.
    @Test func aCloseAfterThePanelLostFocusStillClearsTheQuery() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        fixture.type("e")
        let close = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-close"), launch: .root)
        await clock.waitForSleepers(1)
        fixture.panel.summoner.dismiss(returnFocus: false)
        #expect(fixture.field.text == "e", "a dismiss alone keeps the query")
        clock.advance(by: .seconds(1))
        await close.value
        #expect(fixture.field.text.isEmpty)
        #expect(fixture.hud.shown == ["Done Later"])
    }

    @Test func escapeStillKeepsThePlace() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        fixture.panel.dismiss()
        #expect(fixture.field.text == "e")
    }

    @Test func neverResettingKeepsTheQueryAfterAClose() async {
        let fixture = await PanelFixture.make(settings: ["resetToRootAfter": .int(-1)])
        defer { fixture.close() }
        fixture.type("e")
        fixture.press(.submit([]))
        #expect(await waitUntil { !fixture.opened.value.isEmpty })
        #expect(fixture.field.text == "e")
    }

    @Test func aRunStartedWhileHiddenLeavesThePageTheUserLeft() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        fixture.type("e")
        fixture.panel.dismiss()
        let close = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-close"), launch: .hotkey)
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(1))
        await close.value
        #expect(fixture.field.text == "e")
    }

    @Test func fixedSizingNeverResizesTheGlassWhileTyping() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let surface = fixture.panel.surface
        let height = surface.targetGlassHeight
        for query in ["e", "ex", "zzz", "", "n"] {
            fixture.type(query)
            #expect(surface.targetGlassHeight == height)
        }
        #expect(
            fixture.panel.rootPage.contentView.preferredContentHeight(limit: 10_000) == fixture.panel.fixedContentHeight
        )
    }

    @Test func fitContentSnapsWithoutAnimating() async {
        let fixture = await PanelFixture.make(settings: ["panelSizing": .string("fitContent")])
        defer { fixture.close() }
        let surface = fixture.panel.surface
        surface.accessibilityOverride = DisplayAccessibility()
        let full = surface.targetGlassHeight
        fixture.type("Plain")
        #expect(surface.targetGlassHeight < full)
        #expect(!surface.isAnimatingHeight, "a height change caused by typing snaps")
    }

    @Test func aThemeChangeReachesTheSurface() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "host-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        let fixture = await PanelFixture.make(themes: store)
        defer { fixture.close() }
        #expect(store.select("Ocean"))
        #expect(fixture.panel.surface.theme.lens == Theme.ocean.lens)
        fixture.runtime.fakes.settings.set(.string("Ember"), for: "app.general.themeName")
        #expect(await waitUntil { fixture.panel.surface.theme.lens == Theme.ember.lens })
    }
}

/// Root search with a currency answer on top that fills in later under the same ID, and two
/// results below it.
@MainActor final class AnswerRoot: RootSource {
    let changes = ChangeSignal()
    private(set) var snapshot = RootSnapshot()
    private var revision = 0
    private var answerTitle = "Converting…"

    private func make(_ query: String) -> RootSnapshot {
        revision += 1
        guard !query.isEmpty else { return RootSnapshot(revision: revision) }
        let answer = Row(id: ItemID("calc", "answer"), title: answerTitle, icon: .symbol("equal"))
        let results = [
            Row(id: ItemID("demo", "one"), title: "Currency Rates", icon: .symbol("1.circle")),
            Row(id: ItemID("demo", "two"), title: "Units", icon: .symbol("2.circle")),
        ]
        return RootSnapshot(
            query: query,
            sections: [
                RootSection(id: "answers", title: "Answer", rows: [answer], kind: .answers),
                RootSection(id: "results", title: "Results", rows: results, kind: .results),
            ],
            revision: revision)
    }

    func begin() -> RootSnapshot {
        snapshot = make("")
        return snapshot
    }

    func update(query: String) -> RootSnapshot {
        snapshot = make(query)
        return snapshot
    }

    /// The answer arrived: the same row, with its value.
    func answer(_ title: String) {
        answerTitle = title
        snapshot = make(snapshot.query)
        changes.send()
    }

    func end() {}
    func titleHighlights(for row: Row) -> [Range<Int>] { [] }
    func featureID(for row: Row) -> String? { nil }
    func row(for id: ItemID) -> Row? { snapshot.rows.first { $0.id == id } }
    func didRun(_ row: Row, launch: LaunchSource) {}
    func forget(_ id: ItemID) {}
    func actions(for row: Row) -> [Action] { [Action("Copy " + row.title, id: "copy") { _ in .keepOpen }] }
}
