import Foundation
import Kit
import Testing

@testable import Clipboard

@Suite("The history store", .timeLimit(.minutes(1)))
struct StoreTests {
    private let date = Date(timeIntervalSince1970: 1_794_648_600)

    @Test func recordsEachKindAndGivesItBack() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let png = Samples.png(width: 40, height: 30)
        let captures: [(Capture, PasteboardContent)] = [
            (TemporaryStore.capture("plain words"), .text("plain words")),
            (
                try #require(TemporaryStore.capture([.richText(rtf: Samples.rtf, plain: "Bold words")])),
                .richText(rtf: Samples.rtf, plain: "Bold words")
            ),
            (
                try #require(TemporaryStore.capture([.url(Samples.link), .text(Samples.link.absoluteString)])),
                .url(Samples.link)
            ),
            (TemporaryStore.capture("#FF8800"), .text("#FF8800")),
            (
                try #require(TemporaryStore.capture([.files([Samples.fileA, Samples.fileB])])),
                .files([Samples.fileA, Samples.fileB])
            ),
            (
                try #require(TemporaryStore.capture([.image(png, typeIdentifier: "public.png")])),
                .image(png, typeIdentifier: "public.png")
            ),
        ]
        for (offset, (capture, _)) in captures.enumerated() {
            try await store.record(capture, at: date.addingTimeInterval(Double(offset)))
        }
        for (capture, content) in captures {
            #expect(try await store.content(capture.key) == content)
        }
        #expect(try await store.count() == 6)
        let page = try await store.page(PageRequest())
        #expect(page.items.map(\.kind) == [.image, .files, .color, .link, .richText, .text], "newest first")

        let image = try #require(page.items.first)
        #expect(image.pixelWidth == 40 && image.pixelHeight == 30)
        let imageFile = try #require(image.imageURL)
        let thumbnail = try #require(image.thumbnailURL)
        #expect(imageFile.deletingLastPathComponent() == store.imagesFolder)
        #expect(FileManager.default.fileExists(atPath: imageFile.path))
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(
            store.imagesFolder.deletingLastPathComponent().path == store.databaseURL.deletingLastPathComponent().path,
            "images sit beside the database")
        #expect(store.databaseURL.path.hasPrefix(temporary.folder.path))
    }

    @Test func plainTextFormsDropStylingAndImagesHaveNone() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let rich = try #require(TemporaryStore.capture([.richText(rtf: Samples.rtf, plain: "Bold words")]))
        let link = try #require(TemporaryStore.capture([.url(Samples.link)]))
        let files = try #require(TemporaryStore.capture([.files([Samples.fileA, Samples.fileB])]))
        let image = try #require(
            TemporaryStore.capture([.image(Samples.png(width: 2, height: 2), typeIdentifier: "public.png")]))
        for capture in [rich, link, files, image] { try await store.record(capture, at: date) }
        #expect(try await store.content(rich.key, plainText: true) == .text("Bold words"))
        #expect(try await store.content(link.key, plainText: true) == .text(Samples.link.absoluteString))
        #expect(
            try await store.content(files.key, plainText: true) == .text(Samples.fileA.path + "\n" + Samples.fileB.path)
        )
        #expect(try await store.content(image.key, plainText: true) == nil)
    }

    @Test func copyingAgainMovesTheItemToTheTopAndCountsIt() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let first = TemporaryStore.capture("first")
        let second = TemporaryStore.capture("second")
        try await store.record(first, at: date)
        try await store.record(second, at: date.addingTimeInterval(60))
        try await store.record(first, at: date.addingTimeInterval(120))
        #expect(try await store.keys() == [first.key, second.key])
        #expect(try await store.count() == 2)
        let detail = try #require(try await store.detail(first.key))
        #expect(detail.copyCount == 2)
        #expect(detail.firstCopied == date)
        #expect(detail.summary.copied == date.addingTimeInterval(120))
        let found = try await store.page(PageRequest(query: SearchQuery("first")))
        #expect(found.items.map(\.key) == [first.key], "the search index follows the move")
    }

    @Test func theSameWordsStyledAndPlainAreOneItemThatKeepsTheLatestForm() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let rich = try #require(TemporaryStore.capture([.richText(rtf: Samples.rtf, plain: "Bold words")]))
        let plain = TemporaryStore.capture("Bold words")
        #expect(rich.key == plain.key)
        try await store.record(rich, at: date)
        try await store.record(plain, at: date.addingTimeInterval(1))
        #expect(try await store.count() == 1)
        #expect(try await store.content(plain.key) == .text("Bold words"))
    }

    @Test func searchMatchesAnywhereInTheTextIgnoringCaseAndAccents() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let menu = TemporaryStore.capture("Le menu du Café\nsecond line about soup")
        let other = TemporaryStore.capture("nothing to see")
        try await store.record(menu, at: date)
        try await store.record(other, at: date.addingTimeInterval(1))
        for query in ["cafe", "CAFÉ", "afé", "soup", "menu cafe", "du", "e m"] {
            let page = try await store.page(PageRequest(query: SearchQuery(query)))
            #expect(page.items.map(\.key) == [menu.key], "query \(query)")
        }
        #expect(
            try await store.page(PageRequest(query: SearchQuery("menu zebra"))).items.isEmpty, "every word must match")
        #expect(try await store.page(PageRequest(query: SearchQuery("\"quoted\""))).items.isEmpty)
        #expect(try await store.page(PageRequest(query: SearchQuery("%"))).items.isEmpty, "LIKE wildcards are escaped")
    }

    @Test func pagesWalkTheWholeHistoryOnceNewestFirst() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let captures = (0..<250).map {
            (capture: TemporaryStore.capture("entry \($0)"), date: date.addingTimeInterval(Double($0)))
        }
        try await store.record(batch: captures)
        var seen: [ItemKey] = []
        var request = PageRequest(limit: 100)
        var pages = 0
        while true {
            let page = try await store.page(request)
            seen += page.items.map(\.key)
            pages += 1
            guard let next = page.nextCursor else { break }
            request.cursor = next
        }
        #expect(pages == 3)
        #expect(seen == captures.reversed().map(\.capture.key))
    }

    @Test func pinnedItemsComeOnTheFirstPageOnlyAndFiltersApply() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let pinned = TemporaryStore.capture("pinned note")
        let link = try #require(TemporaryStore.capture([.url(Samples.link)]))
        let text = TemporaryStore.capture("loose note")
        for capture in [pinned, link, text] { try await store.record(capture, at: date) }
        try await store.setPinned(true, key: pinned.key)

        let first = try await store.page(PageRequest(limit: 1))
        #expect(first.pinned.map(\.key) == [pinned.key])
        #expect(first.items.map(\.key) == [text.key])
        let second = try await store.page(PageRequest(cursor: first.nextCursor, limit: 1))
        #expect(second.pinned.isEmpty)
        #expect(second.items.map(\.key) == [link.key])

        #expect(try await store.page(PageRequest(filter: .links)).items.map(\.key) == [link.key])
        let onlyPinned = try await store.page(PageRequest(filter: .pinned))
        #expect(onlyPinned.pinned.map(\.key) == [pinned.key] && onlyPinned.items.isEmpty)
        #expect(try await store.page(PageRequest(query: SearchQuery("note"))).pinned.map(\.key) == [pinned.key])
    }

    @Test func deletingAnImageRemovesItsFiles() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let image = try #require(
            TemporaryStore.capture([.image(Samples.png(width: 8, height: 8), typeIdentifier: "public.png")]))
        try await store.record(image, at: date)
        let summary = try #require(try await store.summary(image.key))
        let files = [try #require(summary.imageURL), try #require(summary.thumbnailURL)]
        #expect(try await store.delete(image.key))
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try await store.delete(image.key) == false)
    }

    @Test func textOffsetsCountTextOnlyNewestFirst() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        try await store.record(TemporaryStore.capture("oldest"), at: date)
        try await store.record(try #require(TemporaryStore.capture([.url(Samples.link)])), at: date)
        try await store.record(
            try #require(
                TemporaryStore.capture([.image(Samples.png(width: 2, height: 2), typeIdentifier: "public.png")])),
            at: date)
        try await store.record(TemporaryStore.capture("newest"), at: date)
        #expect(try await store.text(offset: 0) == "newest")
        #expect(try await store.text(offset: 1) == Samples.link.absoluteString)
        #expect(try await store.text(offset: 2) == "oldest")
        #expect(try await store.text(offset: 3) == nil)
        #expect(try await store.text(offset: -1) == nil)
    }

    @Test func theHistorySurvivesClosingAndOpeningAgain() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        try await temporary.store.record(TemporaryStore.capture("kept"), at: date)
        await temporary.store.close()
        let reopened = HistoryStore(folder: temporary.folder)
        #expect(try await reopened.text(offset: 0) == "kept")
        #expect(try await reopened.page(PageRequest(query: SearchQuery("kept"))).items.count == 1)
    }

    @Test func makingAStoreTouchesNothing() {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        _ = temporary.store
        #expect(!FileManager.default.fileExists(atPath: temporary.folder.path))
    }
}
