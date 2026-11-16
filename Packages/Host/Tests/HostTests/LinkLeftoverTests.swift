import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// What a panel session a link opened leaves for the next summon: nothing. The next session is the
/// user's own, so a query or a page a link left there would run as if the user had typed it.
@Suite("Panel: what a link leaves behind", .serialized, .timeLimit(.minutes(1)))
@MainActor struct LinkLeftoverTests {
    @Test func aLinksTextIsGoneWhenThePanelOpensAgain() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "> echo from a link")
        #expect(panel.isLinkSession(panel.sessionID))
        #expect(panel.rootPage.holdsSelection)

        panel.dismiss()
        panel.summon()
        #expect(!panel.isLinkSession(panel.sessionID))
        #expect(fixture.field.text.isEmpty)
        #expect(panel.rootPage.query.isEmpty)
        #expect(!panel.rootPage.holdsSelection)
    }

    @Test func aPageALinkOpenedIsGoneWhenThePanelOpensAgain() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        await panel.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .deeplink).value
        #expect(panel.top.title == "Shelf")

        panel.dismiss()
        panel.summon()
        #expect(panel.stack.count == 1)
        #expect(fixture.field.text.isEmpty)
    }

    @Test func theUsersOwnSessionStillKeepsItsQueryForTheDelay() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("notes")
        fixture.panel.dismiss()
        fixture.panel.summon()
        #expect(fixture.field.text == "notes")
        #expect(fixture.panel.rootPage.query == "notes")
    }
}
