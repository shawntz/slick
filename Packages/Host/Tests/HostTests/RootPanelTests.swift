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
