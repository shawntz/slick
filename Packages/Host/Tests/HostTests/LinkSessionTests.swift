import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A feature whose commands paste, one of them through a hand-off.
final class Paster: Feature {
    static let manifest = FeatureManifest(id: "paster", name: "Paster", icon: .symbol("doc.on.clipboard"))
    static let pasteNow = ItemID.command(feature: "paster", command: "paste-now")
    static let handOff = ItemID.command(feature: "paster", command: "hand-off")

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "paste-now", title: "Paste Now", requires: [.accessibility]) { context in
                try await context.pasteboard.paste("synthetic text")
                return .close()
            },
            Command(id: "hand-off", title: "Hand Off to Paste") { _ in .run(Self.pasteNow) },
        ]
    }
}

/// What a panel session a link opened may do. Root search selects no row for the link's text,
/// a page can start on a row of its choosing, and every run in the session copies instead of
/// pasting, because the app in front may be the page that fired the link.
@Suite("Panel: links", .serialized, .timeLimit(.minutes(1)))
@MainActor struct LinkSessionTests {
    private func pasterRuntime() async -> (RuntimeFixture, FakePasteboard) {
        let runtime = RuntimeFixture()
        await runtime.runtime.start([FeatureRegistration(Paster.self)])
        return (runtime, runtime.fakes.pasteboard)
    }

    @Test func aRunALinkStartsCopiesInsteadOfPasting() async {
        let (runtime, pasteboard) = await pasterRuntime()
        await runtime.runtime.pipeline.runCommand(Paster.pasteNow, launch: .deeplink).value
        #expect(pasteboard.pastedTexts.isEmpty)
        #expect(pasteboard.copiedTexts == ["synthetic text"])
        #expect(runtime.presenter.toasts.map(\.title) == ["Copied, Not Pasted"])
        #expect(runtime.presenter.toasts.first?.style == .failure)

        await runtime.runtime.pipeline.runCommand(Paster.pasteNow, launch: .root).value
        #expect(pasteboard.pastedTexts == ["synthetic text"])
    }

    @Test func aHandOffFromALinkRunStillCopies() async {
        let (runtime, pasteboard) = await pasterRuntime()
        await runtime.runtime.pipeline.runCommand(Paster.handOff, launch: .deeplink).value
        #expect(pasteboard.pastedTexts.isEmpty)
        #expect(pasteboard.copiedTexts == ["synthetic text"])

        await runtime.runtime.pipeline.runCommand(Paster.handOff, launch: .root).value
        #expect(pasteboard.pastedTexts == ["synthetic text"])
    }

    @Test func aLinksTextSelectsNoRowUntilTheUserMoves() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "notes")
        let visible = panel.isPanelVisible
        #expect(visible)
        #expect(panel.isLinkSession(panel.sessionID))
        #expect(fixture.field.text == "notes")
        #expect(fixture.rootTitles == ["Notes"])
        #expect(panel.rootPage.list.selectedRow == nil)
        #expect(panel.rootPage.holdsSelection)
        #expect(panel.surface.actionBar.content.primaryTitle == nil)

        // Return and Command-1 start nothing.
        fixture.press(.submit([]))
        fixture.command("1")
        #expect(panel.runtime.pipeline.activeRunCount == 0)

        // Root's late sections keep nothing selected.
        fixture.root.simulateLateSection(
            RootSection(
                id: "late", title: "Later", rows: [Row(id: ItemID("web", "1"), title: "Notes Online")],
                kind: .provider(namespace: "web")))
        #expect(await waitUntil { panel.rootPage.list.content.sections.count == 2 })
        #expect(panel.rootPage.list.selectedRow == nil)

        // Down selects the first row, and Return runs it.
        fixture.press(.moveDown)
        #expect(panel.rootPage.list.selectedRow == 0)
        #expect(!panel.rootPage.holdsSelection)
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.opened.value == [SampleRows.note.id] })
    }

    @Test func typingAfterALinkSelectsTheFirstRowAgain() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        fixture.panel.showRootForLink(query: "e")
        #expect(fixture.panel.rootPage.list.selectedRow == nil)
        fixture.type("ex")
        #expect(fixture.panel.rootPage.list.selectedRow == 0)
        fixture.panel.showRootForLink(query: "e")
        fixture.press(.moveUp)
        #expect(fixture.panel.rootPage.list.selectedRow == 0)
        fixture.panel.showRootForLink(query: "e")
        fixture.panel.resetToRoot()
        #expect(!fixture.panel.rootPage.holdsSelection)
    }

    @Test func aRootRunInALinkSessionCopiesAndALaterSessionPastes() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let pasteboard = fixture.runtime.fakes.pasteboard
        fixture.root.rowActions = { _ in [.paste("synthetic text")] }
        fixture.panel.showRootForLink(query: "notes")
        fixture.press(.moveDown)
        fixture.press(.submit([]))
        #expect(await waitUntil { pasteboard.copiedTexts == ["synthetic text"] })
        #expect(await waitUntil { fixture.panel.runtime.pipeline.activeRunCount == 0 })
        #expect(pasteboard.pastedTexts.isEmpty)
        #expect(fixture.panel.surface.actionBar.toast?.text.hasPrefix("Copied, Not Pasted") == true)

        // The user opens the panel again: a new session, and the paste goes through.
        fixture.panel.dismiss()
        fixture.panel.summon()
        #expect(!fixture.panel.isLinkSession(fixture.panel.sessionID))
        fixture.type("notes")
        fixture.press(.submit([]))
        #expect(await waitUntil { pasteboard.pastedTexts == ["synthetic text"] })
    }

    @Test func aPageALinkRunPushesKeepsTheSessionALinkSession() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        await panel.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .deeplink).value
        let visible = panel.isPanelVisible
        #expect(visible)
        #expect(panel.top.title == "Shelf")
        #expect(panel.isLinkSession(panel.sessionID))

        panel.dismiss()
        panel.summon()
        #expect(!panel.isLinkSession(panel.sessionID))
    }

    @Test func aPushedPageCanStartOnAnotherRow() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let rows = ["Alpha", "Beta", "Gamma"].map { Row(id: ItemID("pick", $0.lowercased()), title: $0) }
        let page = ListPageController(
            page: ListPage(sections: [ListSection(rows: rows)], title: "Pick") { _ in [] },
            origin: RunOrigin(
                featureID: HostSettings.namespace, feature: fixture.runtime.runtime.hostContext, launch: .deeplink))
        page.preferredSelection = ItemID("pick", "gamma")
        fixture.panel.pushForLink(page)
        #expect(fixture.panel.isLinkSession(fixture.panel.sessionID))
        #expect(await waitUntil { page.selectedRow?.title == "Gamma" })
        fixture.press(.moveUp)
        #expect(page.selectedRow?.title == "Beta")
        // Filtering keeps the user's row while it shows.
        fixture.type("a")
        #expect(page.selectedRow?.title == "Beta")
    }
}
