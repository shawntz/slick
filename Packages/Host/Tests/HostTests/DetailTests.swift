import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// The detail pane beside a list, and detail pages with streams and follow-ups.
@Suite("Panel: details", .serialized, .timeLimit(.minutes(1)))
@MainActor struct DetailTests {
    // MARK: Pane beside a list

    private func openList(_ fixture: PanelFixture, _ source: GatedSource) async -> ListPageController? {
        let page = fixture.open(.list(ListPage(source, title: "Notes", showsDetail: true)))
        guard let list = page as? ListPageController, await waitUntil({ list.loadCount == 1 }) else { return nil }
        return list
    }

    @Test func thePaneLoadsAfterTheSelectionSettles() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["Alpha", "Beta", "Gamma"])
        let page = try #require(await openList(fixture, source))
        #expect(page.split != nil)
        #expect(source.detailRequests.isEmpty, "nothing loads before the selection rests")
        #expect(await waitUntil { page.detailLoads == 1 })
        #expect(page.split?.detail.bodyText.contains("Alpha") == true)
        #expect(page.split?.detail.content.metadata.first == .label("Kind", value: "Text"))
    }

    @Test func movingOnCancelsTheLoadAndTypingKeepsTheSameRow() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["Alpha", "Beta", "Gamma", "Delta"])
        let page = try #require(await openList(fixture, source))
        fixture.press(.moveDown)
        fixture.press(.moveDown)
        #expect(await waitUntil { page.detailLoads == 1 })
        try await Task.sleep(for: .milliseconds(120))
        #expect(source.detailRequests == [ItemID("gated", "Gamma")], "only the row the selection rested on")
        fixture.type("a")
        try await Task.sleep(for: .milliseconds(120))
        #expect(page.selectedRow?.title == "Gamma")
        #expect(source.detailRequests.count == 1, "the same row does not load again")
    }

    @Test func aFailedDetailClearsThePaneAndShowsAToast() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["Alpha"])
        source.failsDetail = true
        let page = try #require(await openList(fixture, source))
        #expect(await waitUntil { fixture.panel.surface.actionBar.toast != nil })
        #expect(page.split?.detail.content.isEmpty == true)
    }

    // MARK: Detail pages

    private func openDetail(_ fixture: PanelFixture, _ source: Streamer) -> DetailPageController? {
        fixture.open(.detail(DetailPage(title: "Answer", source: source))) as? DetailPageController
    }

    @Test func actionsAreAskedOnOpenOnStreamEndAndOnSignal() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        #expect(source.askedFor == [Detail()])
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Copy Answer")
        source.current?.yield(.append("Hello"))
        source.actionsChanged?.send()
        #expect(await waitUntil { source.askedFor.count == 2 })
        source.current?.finish()
        #expect(await waitUntil { source.askedFor.count == 3 })
        #expect(source.askedFor.last == .markdown("Hello"))
        #expect(!page.isStreaming)
    }

    @Test func appendsAreDrawnOncePerFrame() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        source.current?.yield(.replace(.markdown("")))
        for index in 0..<200 { source.current?.yield(.append("token\(index) ")) }
        let expected = (0..<200).map { "token\($0) " }.joined()
        #expect(await waitUntil { page.detail == .markdown(expected) })
        let trimmed = expected.trimmingCharacters(in: .whitespaces)
        #expect(
            await waitUntil { page.pane.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed },
            "shown: \(page.pane.bodyText.suffix(40).debugDescription)")
        #expect(page.draws < 50, "200 updates drew \(page.draws) times")
    }

    @Test func aFollowUpCancelsTheRunningStreamAndAppliesOnTop() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        #expect(fixture.field.placeholder == "Ask a follow-up")
        source.current?.yield(.replace(.markdown("First answer.")))
        #expect(await waitUntil { page.pane.bodyText == "First answer." })
        fixture.type("why")
        fixture.press(.submit([]))
        #expect(source.followUps == ["why"])
        #expect(await waitUntil { source.cancelledStreams == 1 }, "the running stream was cancelled first")
        #expect(fixture.field.text.isEmpty)
        source.current?.yield(.append(" Because."))
        #expect(await waitUntil { page.pane.bodyText == "First answer. Because." })
        source.current?.finish()
        #expect(await waitUntil { !page.isStreaming })
    }

    @Test func aStreamErrorShowsAToastAndAsksForActions() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        source.current?.yield(.append("Partial"))
        source.current?.finish(throwing: ActionFailure("The model stopped"))
        #expect(await waitUntil { fixture.panel.surface.actionBar.toast?.text == "The model stopped" })
        #expect(source.askedFor.count == 2)
        #expect(page.pane.bodyText == "Partial", "what arrived stays")
        #expect(!page.isStreaming)
    }

    @Test func returnOnAnEmptyFollowUpRunsThePrimaryAction() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        _ = try #require(openDetail(fixture, source))
        fixture.press(.submit([]))
        #expect(source.followUps.isEmpty)
    }

    @Test func richTextShowsPlainThenItsStyledRuns() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let styled = NSMutableAttributedString(string: "Plain ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        styled.append(NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        let rtf = try #require(
            styled.rtf(from: NSRange(location: 0, length: styled.length), documentAttributes: [:]))
        let page = try #require(
            fixture.open(.detail(DetailPage(detail: Detail(.richText(rtf: rtf, plain: "Plain bold")))))
                as? DetailPageController)
        #expect(
            await waitUntil {
                guard case .richText(let rich) = page.pane.content.body else { return false }
                return rich.plainText == "Plain bold" && rich.runs.map(\.isBold) == [false, true]
                    && rich.runs.allSatisfy { $0.sizeScale == 1 }
            })
    }

    /// A script's output keeps its colour codes, whole or cut between two appends, for the pane to
    /// draw as colour.
    @Test func streamedTextKeepsItsColourCodes() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        source.current?.yield(.replace(Detail(.text("", monospaced: true))))
        page.drawPendingUpdates()
        source.current?.yield(.append("\u{1B}[3"))
        source.current?.yield(.append("1mred\u{1B}[0m"))
        #expect(await waitUntil { page.detail.body == .text("\u{1B}[31mred\u{1B}[0m", monospaced: true) })
        page.drawPendingUpdates()
        #expect(page.pane.bodyText == "red", "the pane draws the codes as colour, not as text")
    }

    /// A metadata label's icon draws before its value: a symbol at once, an app icon when the
    /// icon provider has it.
    @Test func metadataIconsDrawBeforeTheirValues() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let app = Icon.app(bundleID: "com.example.editor")
        fixture.icons.holdBack(app)
        let detail = Detail(
            .markdown("Body"),
            metadata: [
                .label("Kind", value: "Folder", icon: .symbol("folder")),
                .label("Opens In", value: "Editor", icon: app),
            ])
        let page = try #require(fixture.open(.detail(DetailPage(detail: detail))) as? DetailPageController)
        #expect(await waitUntil { page.pane.content.metadata.count == 2 })
        #expect(page.pane.content.metadata[0] == .iconLabel("Kind", value: "Folder", icon: .symbol("folder")))
        #expect(page.pane.content.metadata[1] == .label("Opens In", value: "Editor"))
        fixture.icons.deliverHeldIcons()
        #expect(
            await waitUntil {
                if case .iconLabel(_, _, .image) = page.pane.content.metadata[1] { return true }
                return false
            })
        #expect(page.pane.content.body == .markdown("Body"))
    }

    @Test func reloadStartsTheStreamAgain() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(openDetail(fixture, source))
        source.current?.yield(.append("Old"))
        #expect(await waitUntil { page.pane.bodyText == "Old" })
        page.reload()
        #expect(page.streamsStarted == 2)
        #expect(await waitUntil { source.cancelledStreams == 1 })
        #expect(page.detail == Detail())
        fixture.press(.cancel([]))
        #expect(fixture.panel.top === fixture.panel.rootPage)
        #expect(await waitUntil { source.cancelledStreams == 2 }, "leaving the page cancels its stream")
    }

    @Test func detailsMapToThePane() {
        let date = Date(timeIntervalSince1970: 0)
        let content = DetailMapping.content(
            Detail(
                .text("\u{1B}[31mred\u{1B}[0m text", monospaced: true),
                metadata: [
                    .label("Size", value: "2 KB", icon: .symbol("doc")),
                    .link("Site", text: "example.com", url: URL(string: "https://example.com")!),
                    .color("Accent", .rgba(red: 0, green: 0.5, blue: 1, alpha: 1)), .date("Created", date),
                    .separator,
                ]))
        #expect(content.body == .monospaced("\u{1B}[31mred\u{1B}[0m text"), "the pane draws the codes as colour")
        #expect(content.metadata[0] == .iconLabel("Size", value: "2 KB", icon: .symbol("doc")))
        #expect(content.metadata[1] == .link("Site", text: "example.com", url: "https://example.com"))
        #expect(
            content.metadata[2] == .color("Accent", ThemeColor(red: 0, green: 0.5, blue: 1, alpha: 1), text: "#0080FF"))
        #expect(content.metadata[4] == .separator)
        #expect(
            DetailMapping.content(Detail(.richText(rtf: Data(), plain: "Plain"))).body == .text("Plain"),
            "rich text shows its plain form while its runs are read")
        #expect(
            DetailMapping.content(Detail(.link(URL(string: "https://example.com/a_b")!))).body
                == .markdown("[https://example.com/a\\_b](https://example.com/a_b)"))
    }
}
