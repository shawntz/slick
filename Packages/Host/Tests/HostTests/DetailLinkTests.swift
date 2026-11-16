import AppKit
import Foundation
import Host
import Kit
import KitTesting
import LauncherUI
import Testing

/// A link in a detail opens a web or mail address at once. Any other target, a file included,
/// shows in full in a toast first and opens only from the toast's Open button.
@Suite("Panel: links in details", .serialized, .timeLimit(.minutes(1)))
@MainActor struct DetailLinkTests {
    private let web = URL(string: "https://example.com/report")!
    private let mail = URL(string: "mailto:someone@example.com")!
    private let file = URL(string: "file:///tmp/example/report.app")!
    private let otherApp = URL(string: "example-app://do?thing=1")!

    @Test func webAndMailLinksOpenAtOnceAndOthersAsk() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let workspace = fixture.runtime.fakes.workspace
        let page = try #require(
            fixture.open(.detail(DetailPage(title: "Answer", detail: .markdown("See [the report](x)."))))
                as? DetailPageController)

        page.pane.onOpenLink?(web)
        page.pane.onOpenLink?(mail)
        #expect(await waitUntil { workspace.opened == [web, mail] })
        #expect(fixture.panel.surface.actionBar.toast == nil)

        for target in [file, otherApp] {
            page.pane.onOpenLink?(target)
            #expect(fixture.panel.surface.actionBar.toast?.text == "Not a Web Link: \(target.absoluteString)")
            #expect(fixture.panel.surface.actionBar.toast?.buttonTitle == "Open")
            try await Task.sleep(for: .milliseconds(20))
            #expect(workspace.opened == [web, mail], "nothing opens before the user presses Open")
        }

        // The toast's button opens the target it shows, and only that one.
        fixture.panel.runToastAction()
        #expect(await waitUntil { workspace.opened == [web, mail, otherApp] })
    }

    @Test func theToastsOpenEntryLeadsTheActionPanel() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let workspace = fixture.runtime.fakes.workspace
        let page = try #require(
            fixture.open(
                .detail(
                    DetailPage(
                        title: "Answer", detail: .markdown("text"),
                        actions: [Action("Copy Answer", id: "copy") { _ in .keepOpen }])))
                as? DetailPageController)
        page.pane.onOpenLink?(file)
        fixture.command("k")
        #expect(fixture.panel.actionEntries.map(\.title) == ["Open", "Copy Answer"])
        fixture.panel.actionCard.onActivate?(ActionItem(id: "0", title: "Open"))
        #expect(await waitUntil { workspace.opened == [file] })
    }

    @Test func aListsDetailPaneFollowsTheSameRule() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let workspace = fixture.runtime.fakes.workspace
        let source = GatedSource(titles: ["Alpha"])
        let page = try #require(
            fixture.open(.list(ListPage(source, title: "Notes", showsDetail: true))) as? ListPageController)
        let pane = try #require(page.split?.detail)
        pane.onOpenLink?(web)
        #expect(await waitUntil { workspace.opened == [web] })
        pane.onOpenLink?(file)
        #expect(fixture.panel.surface.actionBar.toast?.text == "Not a Web Link: \(file.absoluteString)")
        try await Task.sleep(for: .milliseconds(20))
        #expect(workspace.opened == [web])
    }
}
