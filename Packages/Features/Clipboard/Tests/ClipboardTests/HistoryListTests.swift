import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

@Suite("The Clipboard History page", .timeLimit(.minutes(1)))
@MainActor
struct HistoryListTests {
    @Test func showsPinnedItemsFirstThenOneSectionPerDay() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("from two days ago")
        try await clipboard.copy("pinned long ago")
        clipboard.advance(minutes: 24 * 60)
        try await clipboard.copy("from yesterday")
        clipboard.advance(minutes: 24 * 60)
        try await clipboard.copy("from today")
        try await clipboard.store.setPinned(true, key: ClipboardHarness.textKey("pinned long ago"))

        try await clipboard.openHistory()
        let harness = clipboard.harness
        #expect(harness.sections.map(\.title) == ["Pinned", "Today", "Yesterday", "Saturday"])
        #expect(harness.sections.map(\.id) == ["pinned", "day-2026-11-16", "day-2026-11-15", "day-2026-11-14"])
        #expect(harness.rows.map(\.title) == ["pinned long ago", "from today", "from yesterday", "from two days ago"])
        #expect(harness.selectedRow?.title == "pinned long ago")
        let row = try #require(harness.rows.dropFirst().first)
        #expect(row.accessories.first == .icon(.app(bundleID: ClipboardHarness.editor), tooltip: "Example Editor"))
        #expect(row.memory == .never)
        #expect(row.represents == .text("from today"))
        #expect(harness.issues.isEmpty)
    }

    @Test func theTypeDropdownFiltersAndRemembersNothingItShouldNot() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("plain words")
        try await clipboard.copy([.url(Samples.link)], from: ClipboardHarness.browser)
        try await clipboard.copy("#FF8800")
        try await clipboard.copy([.files([Samples.fileA])])
        try await clipboard.copy([.image(Samples.png(width: 12, height: 10), typeIdentifier: "public.png")])
        try await clipboard.openHistory()
        let harness = clipboard.harness
        #expect(
            harness.page?.dropdown?.options.map(\.id) == [
                "all", "pinned", "text", "images", "links", "files", "colors",
            ])
        #expect(harness.rows.count == 5)

        try await harness.setFilter("links")
        #expect(harness.rows.map(\.title) == [Samples.link.absoluteString])
        try await harness.setFilter("colors")
        #expect(harness.rows.map(\.icon) == [.color(try #require(KitColor(hex: "#FF8800")))])
        try await harness.setFilter("files")
        #expect(harness.rows.map(\.title) == ["notes-a.txt"])
        #expect(harness.rows.first?.quickLookURL == Samples.fileA)
        #expect(harness.rows.first?.represents == .files([Samples.fileA]))
        try await harness.setFilter("images")
        let image = try #require(harness.rows.first)
        #expect(image.title == "Image (12 \u{00D7} 10)")
        guard case .image(let thumbnail) = image.icon else {
            Issue.record("an image row shows its thumbnail")
            return
        }
        #expect(FileManager.default.fileExists(atPath: thumbnail))
        try await harness.setFilter("pinned")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == Strings.List.emptyPinnedTitle)
        try await harness.setFilter("text")
        #expect(harness.rows.map(\.title) == ["plain words"])
    }

    @Test func searchingFindsTextAnywhereAndHighlightsTheTitle() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("Meeting notes for the café")
        try await clipboard.copy("grocery list")
        try await clipboard.copy("Second line holds it\nthe word: banana")
        try await clipboard.openHistory()
        let harness = clipboard.harness

        try await harness.setQuery("cafe")
        #expect(harness.rows.map(\.title) == ["Meeting notes for the café"])
        #expect(harness.rows.first?.titleHighlights == [22..<26])

        try await harness.setQuery("banana")
        #expect(harness.rows.map(\.title) == ["Second line holds it"], "matches beyond the first line")
        #expect(harness.rows.first?.titleHighlights == [])

        try await harness.setQuery("notes meet")
        #expect(harness.rows.first?.titleHighlights == [0..<4, 8..<13])

        try await harness.setQuery("zebra")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == Strings.List.noMatchesTitle)
    }

    @Test func fiftyThousandItemsLoadAPageAtATime() async throws {
        let clipboard = await ClipboardHarness()
        let now = clipboard.fakes.clock.now
        let captures = (0..<250).map {
            (capture: TemporaryStore.capture("item number \($0)"), date: now.addingTimeInterval(Double($0) - 250))
        }
        try await clipboard.store.record(batch: captures)
        try await clipboard.openHistory()
        let harness = clipboard.harness
        #expect(harness.rows.count == HistoryList.pageSize)
        #expect(harness.rows.first?.title == "item number 249")
        #expect(try await harness.loadNextPage())
        #expect(harness.rows.count == 200)
        #expect(harness.sections.count == 1, "the next page joins the day it belongs to")
        #expect(try await harness.loadNextPage())
        #expect(harness.rows.count == 250)
        #expect(harness.rows.last?.title == "item number 0")
        #expect(try await harness.loadNextPage() == false)
        #expect(Set(harness.rows.map(\.id)).count == 250)
    }

    @Test func anEmptyHistorySaysHowToFillIt() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.openHistory()
        #expect(clipboard.harness.rows.isEmpty)
        #expect(clipboard.harness.page?.emptyState?.title == Strings.List.emptyTitle)
        #expect(clipboard.harness.page?.notice == nil)
    }

    @Test func aNewCopyShowsUpOnTheOpenPage() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.openHistory()
        try await clipboard.copy("arrives while open")
        #expect(clipboard.harness.rows.map(\.title) == ["arrives while open"])
    }

    @Test func whilePausedABannerOffersToResume() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.isPaused] = true
        try await clipboard.harness.settle()
        try await clipboard.openHistory()
        let notice = try #require(clipboard.harness.page?.notice)
        #expect(notice.title == Strings.List.pausedTitle)
        let resume = try #require(notice.action)
        try await clipboard.harness.perform(resume, row: nil)
        try await clipboard.harness.settle()
        #expect(clipboard.settings[ClipboardSettings.isPaused] == false)
        #expect(clipboard.feature.isMonitoring)
        #expect(clipboard.harness.page?.notice == nil, "the page reloads on the setting")
    }

    @Test func withoutAccessABannerOffersToAllowIt() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.pasteboard, to: .denied)
        let clipboard = await ClipboardHarness(fakes: fakes)
        try await clipboard.openHistory()
        let notice = try #require(clipboard.harness.page?.notice)
        #expect(notice.title == Strings.List.notAllowedTitle)
        #expect(notice.action?.requires == [.pasteboard])
        clipboard.harness.grantsMissingPermissions = true
        try await clipboard.harness.perform(try #require(notice.action), row: nil)
        #expect(fakes.permissions.requests == [.pasteboard], "only the button asks")
        try await clipboard.harness.settle()
        #expect(clipboard.harness.page?.notice == nil)
    }

    @Test func theDetailShowsTheItemWithItsSourceTimeSizeAndType() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("two words")
        clipboard.advance(minutes: 5)
        try await clipboard.copy("two words")
        try await clipboard.openHistory()
        let detail = try #require(try await clipboard.harness.loadDetail())
        #expect(detail.body == .text("two words", monospaced: false))
        let start = Date(timeIntervalSince1970: 1_794_648_600)
        #expect(
            detail.metadata == [
                .tags("Type", [Tag("Text", color: .accent)]),
                .label("Application", value: "Example Editor", icon: .app(bundleID: ClipboardHarness.editor)),
                .label("Characters", value: "9"),
                .label("Words", value: "2"),
                .label("Size", value: "9 bytes"),
                .separator,
                .date("Copied", start.addingTimeInterval(300)),
                .date("First copied", start),
                .label("Times copied", value: "2"),
            ])
    }

    @Test func theDetailSuitsEachKind() async throws {
        let clipboard = await ClipboardHarness()
        let png = Samples.png(width: 20, height: 10)
        try await clipboard.copy([.image(png, typeIdentifier: "public.png")], from: nil)
        try await clipboard.copy([.files([Samples.fileA, Samples.fileB])])
        try await clipboard.copy("#00FF00")
        try await clipboard.copy([.url(Samples.link)])
        try await clipboard.copy([.richText(rtf: Samples.rtf, plain: "Bold words")])
        try await clipboard.openHistory()
        let harness = clipboard.harness

        #expect(try await harness.loadDetail()?.body == .richText(rtf: Samples.rtf, plain: "Bold words"))
        try harness.select(at: 1)
        let link = try #require(try await harness.loadDetail())
        #expect(link.body == .link(Samples.link))
        #expect(link.metadata.contains(.link("Link", text: "example.com", url: Samples.link)))
        try harness.select(at: 2)
        #expect(try await harness.loadDetail()?.body == .color(try #require(KitColor(hex: "#00FF00"))))
        try harness.select(at: 3)
        let files = try #require(try await harness.loadDetail())
        #expect(files.body == .text(Samples.fileA.path + "\n" + Samples.fileB.path))
        #expect(files.metadata.contains(.label("Items", value: "2")))
        try harness.select(at: 4)
        let image = try #require(try await harness.loadDetail())
        guard case .image(.file(let url)) = image.body else {
            Issue.record("an image shows its file")
            return
        }
        #expect(try Data(contentsOf: url) == png)
        #expect(image.metadata.contains(.label("Dimensions", value: "20 \u{00D7} 10 pixels")))
        #expect(!image.metadata.contains { if case .label("Application", _, _) = $0 { true } else { false } })
    }
}
