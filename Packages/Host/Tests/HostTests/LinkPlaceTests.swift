import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A link that arrives while the user works in the panel asks over the page they have open, and
/// every way back returns them to it. In a session a link opened, a destructive question holds its
/// button for a second, as the page that asks does.
@Suite("Panel: links and the user's place", .serialized, .timeLimit(.minutes(1)))
@MainActor struct LinkPlaceTests {
    /// A page like the one that asks before a link runs a command: Run, then Cancel, selected.
    private func askingPage(_ fixture: PanelFixture, _ name: String = "Run Plain") -> ListPageController {
        let rows = [
            Row(id: ItemID("ask", "run"), title: name, memory: .never),
            Row(id: ItemID("ask", "cancel"), title: "Cancel", memory: .never),
        ]
        let page = ListPageController(
            page: ListPage(sections: [ListSection(rows: rows)], title: "Open Link") { _ in [] },
            origin: RunOrigin(
                featureID: HostSettings.namespace, feature: fixture.runtime.runtime.hostContext, launch: .deeplink))
        page.preferredSelection = ItemID("ask", "cancel")
        return page
    }

    /// The Workbench shelf, filtered to "a" with the second row selected.
    private func usersPage(_ fixture: PanelFixture) async throws -> ListPageController {
        let page = try #require(
            fixture.open(.list(ListPage(fixture.runtime.workbench.shelf, title: "Shelf"))) as? ListPageController)
        #expect(await waitUntil { page.loadCount == 1 })
        fixture.type("an")
        fixture.press(.moveDown)
        #expect(page.selectedRow?.title == "Banana")
        return page
    }

    @Test func aLinksPageGoesOverTheUsersPageAndCancelReturnsToIt() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        let shelf = try await usersPage(fixture)
        let asking = askingPage(fixture)
        panel.pushForLink(asking)
        #expect(panel.stack.count == 3)
        #expect(panel.top === asking)
        #expect(panel.isLinkSession(panel.sessionID))
        #expect(await waitUntil { asking.selectedRow?.title == "Cancel" })

        // Cancel answers with "back to root", as the page's action does.
        panel.apply(.popToRoot, origin: asking.origin)
        #expect(panel.top === shelf)
        #expect(fixture.field.text == "an")
        #expect(shelf.selectedRow?.title == "Banana")
        #expect(fixture.titles(shelf.list) == ["Banana"])
    }

    /// Found in review: Command-1 ran the first row of a link's page, Run, while Cancel was
    /// selected. Only the selected row runs there.
    @Test func commandNumbersRunNoRowOfALinksPage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let ran = Box<[String]>([])
        func page() -> ListPageController {
            let rows = [
                Row(id: ItemID("ask", "run"), title: "Run Plain", memory: .never),
                Row(id: ItemID("ask", "cancel"), title: "Cancel", memory: .never),
            ]
            let page = ListPageController(
                page: ListPage(sections: [ListSection(rows: rows)], title: "Open Link") { row in
                    [
                        Action(row.title, id: row.id.key) { _ in
                            ran.value.append(row.title)
                            return .keepOpen
                        }
                    ]
                },
                origin: RunOrigin(
                    featureID: HostSettings.namespace, feature: fixture.runtime.runtime.hostContext, launch: .deeplink))
            page.preferredSelection = ItemID("ask", "cancel")
            return page
        }
        let asking = page()
        fixture.panel.pushForLink(asking)
        #expect(await waitUntil { asking.selectedRow?.title == "Cancel" })
        fixture.command("1")
        fixture.command("2")
        fixture.press(.submit([]))
        #expect(await waitUntil { ran.value == ["Cancel"] })

        // On a page the user opened, the same key runs the first row.
        fixture.panel.pop()
        let own = page()
        fixture.panel.push(own)
        #expect(await waitUntil { own.selectedRow?.title == "Cancel" })
        fixture.command("1")
        #expect(await waitUntil { ran.value == ["Cancel", "Run Plain"] })
    }

    @Test func backAndCommandEscapeAlsoReturnToTheUsersPage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        let shelf = try await usersPage(fixture)
        panel.pushForLink(askingPage(fixture))
        fixture.press(.cancel([]))
        #expect(panel.top === shelf)

        panel.pushForLink(askingPage(fixture))
        fixture.press(.cancel(.command))
        #expect(panel.top === shelf)
        // From the user's own page, Command-Escape goes back to root search as always.
        fixture.press(.cancel(.command))
        #expect(panel.top === panel.rootPage)
    }

    @Test func aSecondLinkReplacesTheFirstLinksPage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        let shelf = try await usersPage(fixture)
        panel.pushForLink(askingPage(fixture, "Run Plain"))
        let second = askingPage(fixture, "Run Echo")
        panel.pushForLink(second)
        #expect(panel.stack.count == 3)
        #expect(panel.top === second)
        panel.popToRoot()
        #expect(panel.top === shelf)
    }

    @Test func aRunTheLinksPageStartsLandsOverTheUsersPage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        let shelf = try await usersPage(fixture)
        panel.pushForLink(askingPage(fixture))
        // As the router does on Run: back from its page, then the run.
        panel.popToRoot()
        await panel.runtime.pipeline.runCommand(RuntimeFixture.command("open-ledger"), launch: .deeplink).value
        #expect(panel.top.title == "Ledger")
        #expect(panel.stack.count == 3)
        fixture.press(.cancel([]))
        #expect(panel.top === shelf)
    }

    @Test func aCardOrTheActionPanelClosesWhenALinksPageArrives() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        _ = try await usersPage(fixture)
        fixture.command("k")
        #expect(panel.surface.overlay === panel.actionCard)
        panel.pushForLink(askingPage(fixture))
        #expect(panel.surface.overlay == nil)

        fixture.press(.cancel([]))
        let answer = Box<Bool?>(nil)
        Task { answer.value = await panel.confirm(Confirmation("Clear everything?"), isDestructive: false) }
        #expect(await waitUntil { panel.pendingCard != nil })
        panel.pushForLink(askingPage(fixture))
        #expect(await waitUntil { answer.value == false })
        #expect(panel.surface.overlay == nil)
    }

    @Test func whileThePanelIsHiddenALinksPageOpensOverRootSearch() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        _ = try await usersPage(fixture)
        panel.dismiss()
        let asking = askingPage(fixture)
        panel.pushForLink(asking)
        #expect(panel.isPanelVisible)
        #expect(panel.stack.count == 2)
        #expect(panel.top === asking)
    }

    @Test func aSearchLinkOverALinksPageShowsRootSearch() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        _ = try await usersPage(fixture)
        panel.pushForLink(askingPage(fixture))
        panel.showRootForLink(query: "notes")
        #expect(panel.top === panel.rootPage)
        #expect(panel.stack.count == 1)
        #expect(fixture.field.text == "notes")
    }

    // MARK: A destructive question in a link session

    private func ask(_ panel: PanelController, destructive: Bool) -> Box<Bool?> {
        let answer = Box<Bool?>(nil)
        let confirmation = Confirmation("Erase every item?", confirmTitle: "Erase", isDestructive: destructive)
        Task { answer.value = await panel.confirm(confirmation, isDestructive: destructive) }
        return answer
    }

    /// The card starts on Cancel, so the Return meant for the page before cancels. Tab moves to the
    /// confirm button, which still waits for the second. A held press keeps the card at once, with
    /// no answer, so the checks need no wait.
    @Test func aDestructiveQuestionInALinkSessionHoldsItsButtonForASecond() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "")
        let answer = ask(panel, destructive: true)
        #expect(await waitUntil { panel.pendingCard != nil })
        let card = try #require(panel.pendingCard)
        #expect(card.content.startsOnCancel && card.returnCancels)

        card.keyDown(with: PanelFixture.tabKey())
        #expect(!card.returnCancels)
        card.keyDown(with: PanelFixture.returnKey())
        #expect(panel.pendingCard === card, "the press before the second is up answers nothing")
        #expect(panel.surface.overlay === card, "the card stays")
        #expect(panel.surface.actionBar.toast?.text.hasPrefix("Wait a Moment") == true)

        fixture.runtime.fakes.clock.advance(by: .milliseconds(999))
        card.keyDown(with: PanelFixture.returnKey())
        #expect(panel.pendingCard === card && panel.surface.overlay === card)

        fixture.runtime.fakes.clock.advance(by: .milliseconds(1))
        card.keyDown(with: PanelFixture.returnKey())
        #expect(await waitUntil { answer.value == true })
    }

    @Test func returnOnAHeldQuestionCancelsAtOnce() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "")
        let answer = ask(panel, destructive: true)
        #expect(await waitUntil { panel.pendingCard != nil })
        panel.pendingCard?.keyDown(with: PanelFixture.returnKey())
        #expect(await waitUntil { answer.value == false })
    }

    @Test func escapeWorksAtOnceOnAHeldQuestion() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "")
        let answer = ask(panel, destructive: true)
        #expect(await waitUntil { panel.pendingCard != nil })
        panel.pendingCard?.cancelOperation(nil)
        #expect(await waitUntil { answer.value == false })
    }

    @Test(arguments: [(link: false, destructive: true), (link: true, destructive: false)])
    func otherQuestionsAnswerAtOnce(link: Bool, destructive: Bool) async throws {
        let fixture = await PanelFixture.make(summon: !link)
        defer { fixture.close() }
        let panel = fixture.panel
        if link { panel.showRootForLink(query: "") }
        let answer = ask(panel, destructive: destructive)
        #expect(await waitUntil { panel.pendingCard != nil })
        #expect(panel.pendingCard?.returnCancels == false)
        panel.pendingCard?.keyDown(with: PanelFixture.returnKey())
        #expect(await waitUntil { answer.value == true })
    }
}
