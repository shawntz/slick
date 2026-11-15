import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@_spi(RootBench) @testable import Root

/// A reference model of the engine's query affinity, ported from the rules in
/// `slick_predict::affinity`: per-prefix rows, credit 1 for the query and 0.5 for shorter prefixes,
/// self-decay 0.7 per credit, at most 8 entries, entries under 0.02 dropped, a learned band from
/// weight 1.1 whose holder changes only on another item's second credit in a row. Time stands still
/// in the tests that use it, so time decay is left out.
struct AffinityModel {
    struct Entry {
        var item: String
        var weight: Float
    }

    struct Line {
        var entries: [Entry] = []
        var holder: String?
        var last: String?
    }

    static let gamma = 0.7
    static let eta = 0.5
    static let band = 1.1
    /// Weights this close to the band or to each other are left unjudged: the engine stores f32 and
    /// stamps rows in f32 minutes, so its weights may differ from the model's by about 1e-5.
    static let margin: Float = 1e-3

    var lines: [String: Line] = [:]

    mutating func learn(_ query: String, item: String) {
        let characters = Array(query)
        for end in 1...characters.count {
            let prefix = String(characters[..<end])
            let credit = end == characters.count ? 1.0 : Self.eta
            var line = lines[prefix] ?? Line()
            let holder = Self.bandHolder(line)?.item
            let factor = pow(Self.gamma, credit)
            for index in line.entries.indices {
                line.entries[index].weight = Float(Double(line.entries[index].weight) * factor)
            }
            if let index = line.entries.firstIndex(where: { $0.item == item }) {
                line.entries[index].weight += Float(credit)
            } else {
                line.entries.append(Entry(item: item, weight: Float(credit)))
            }
            line.entries.removeAll { $0.weight < 0.02 }
            if line.entries.count > 8 {
                line.entries.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.item < $1.item }
                line.entries.removeLast(line.entries.count - 8)
            }
            line.holder = holder
            if item != holder, line.last == item, let strongest = Self.strongest(line), strongest.item == item,
                Double(strongest.weight) >= Self.band
            {
                line.holder = item
            }
            line.holder = Self.bandHolder(line)?.item
            line.last = item
            lines[prefix] = line
        }
    }

    /// The band holder of a query, or nil. `certain` is false when a weight that decides it sits
    /// within ``margin`` of the band or of a rival.
    func holder(of query: String) -> (item: String?, certain: Bool) {
        guard let line = lines[query] else { return (nil, true) }
        var certain = true
        for entry in line.entries where abs(Double(entry.weight) - Self.band) < Double(Self.margin) {
            certain = false
        }
        let sorted = line.entries.map(\.weight).sorted(by: >)
        if sorted.count > 1, sorted[0] - sorted[1] < Self.margin { certain = false }
        return (Self.bandHolder(line)?.item, certain)
    }

    static func strongest(_ line: Line) -> Entry? {
        var top: Entry?
        for entry in line.entries where top.map({ entry.weight > $0.weight }) ?? true {
            top = entry
        }
        return top
    }

    static func bandHolder(_ line: Line) -> Entry? {
        if let holder = line.holder, let entry = line.entries.first(where: { $0.item == holder }),
            Double(entry.weight) >= band
        {
            return entry
        }
        return strongest(line).flatMap { Double($0.weight) >= band ? $0 : nil }
    }
}

@Suite struct AttackTests {
    // MARK: Ranking contract from random histories

    @Test(arguments: [UInt64(1), 2, 3])
    func theLearnedBandMatchesTheModelAndOrderIsStableUnderRandomHistories(seed: UInt64) async throws {
        let fixture = await RootFixture.ready()
        let root = fixture.root
        var generator = SplitMix64(seed: seed)
        var model = AffinityModel()
        let queries = ["t", "te", "ter", "term", "e", "ed", "m", "mu", "c", "ca", "p", "pr", "r", "re"]
        var judged = 0
        for step in 0..<150 {
            let query = queries[Int(generator.next() % UInt64(queries.count))]
            _ = root.begin()
            let results = root.update(query: query).sections.first { $0.kind == .results }?.rows ?? []
            guard !results.isEmpty else {
                root.end()
                continue
            }
            // Picks favor the first rows, as people do, but reach every row.
            let index = Int(generator.next() % UInt64(min(results.count, 4)))
            let row = results[index]
            root.didRun(row, launch: .root)
            root.end()
            model.learn(query, item: row.id.rawValue)
            await root.settle()

            for checked in queries {
                let expected = model.holder(of: checked)
                guard expected.certain, let holder = expected.item else { continue }
                _ = root.begin()
                let first = root.update(query: checked).sections.first { $0.kind == .results }?.rows.first
                let again = root.update(query: checked).rows.map(\.id)
                let third = root.update(query: checked).rows.map(\.id)
                root.end()
                #expect(first?.id.rawValue == holder, "step \(step), query \(checked)")
                #expect(again == third, "the same query in the same state keeps its order")
                judged += 1
            }
        }
        #expect(judged > 100)
        await fixture.shutdown()
    }

    @Test func anAliasAlwaysBeatsTheLearnedBand() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        #expect(fixture.results("term").first == "Terminal")
        fixture.preferences.setAlias("term", for: fixture.apps.id("Music"))
        await fixture.settle()
        #expect(fixture.results("term").first == "Music")
        await fixture.shutdown()
    }

    @Test func anAliasThatEqualsAnotherItemsTitleWins() async throws {
        let fixture = await RootFixture.ready()
        fixture.preferences.setAlias("Term", for: fixture.apps.id("Calendar"))
        await fixture.settle()
        #expect(fixture.results("term").prefix(2) == ["Calendar", "Term"])
        #expect(fixture.results("ter").first == "Calendar")

        // An alias equal to another title that is also a prefix of the query's own alias match.
        fixture.preferences.setAlias("terminal", for: fixture.apps.id("Editor"))
        await fixture.settle()
        #expect(fixture.results("terminal").prefix(2) == ["Editor", "Terminal"])
        #expect(fixture.results("term").prefix(3) == ["Calendar", "Editor", "Term"])

        // Alias picks are not typed learning: once the aliases go, the exact title wins again.
        _ = fixture.root.begin()
        let calendar = try #require(fixture.root.update(query: "term").rows.first)
        #expect(calendar.title == "Calendar")
        fixture.root.didRun(calendar, launch: .root)
        fixture.root.didRun(calendar, launch: .root)
        fixture.root.end()
        fixture.preferences.setAlias(nil, for: fixture.apps.id("Calendar"))
        fixture.preferences.setAlias(nil, for: fixture.apps.id("Editor"))
        await fixture.settle()
        #expect(fixture.results("term").first == "Term")
        await fixture.shutdown()
    }

    // MARK: Changes while the user looks

    @Test func aCatalogChangeDuringAQueryUpdatesRowsInPlaceAndNeverReorders() async throws {
        let fixture = await RootFixture.ready(extraSources: [NumberedItems(count: 3)])
        let books = fixture.library.books
        books.rows.append(Row(id: ItemID("book", "3"), title: "Garden Notes", subtitle: "Shelf C"))
        books.signal.send()
        await fixture.settle()
        let root = fixture.root
        _ = root.begin()
        let typed = root.update(query: "garden")
        let titles = typed.sections.first { $0.kind == .results }?.rows.map(\.title) ?? []
        #expect(titles.contains("Garden Atlas") && titles.contains("Garden Notes"))

        let changes = root.changes.generation
        books.rows = [
            Row(id: ItemID("book", "1"), title: "Example Book", subtitle: "Shelf A"),
            Row(id: ItemID("book", "2"), title: "Garden Atlas", subtitle: "Moved to Shelf D"),
            Row(id: ItemID("book", "4"), title: "Garden Plans", subtitle: "Shelf E"),
        ]
        books.signal.send()
        await fixture.settle()
        let after = root.snapshot
        #expect(root.changes.generation > changes)
        let results = after.sections.first { $0.kind == .results }?.rows ?? []
        #expect(results.map(\.title) == titles.filter { $0 != "Garden Notes" })
        #expect(results.first { $0.title == "Garden Atlas" }?.subtitle == "Moved to Shelf D")
        #expect(!results.contains { $0.title == "Garden Plans" })
        #expect(after.query == "garden")

        // The next keystroke ranks the new catalog.
        #expect(root.update(query: "garden p").rows.contains { $0.title == "Garden Plans" })
        root.end()
        await fixture.shutdown()
    }

    @Test func aFeatureTurnedOffWhileItsRowsShowLosesThemAtOnce() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "garden")
        await fixture.passDebounce()
        let before = root.snapshot
        #expect(before.rows.contains { $0.title == "Garden Atlas" })
        #expect(before.sections.contains { $0.id == "async.web" })
        #expect(before.sections.contains { $0.kind == .fallbacks })

        await fixture.preferences.setEnabled(false, feature: SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(!root.snapshot.sections.contains { $0.id == "async.web" || $0.id == "async.mail" })

        await fixture.preferences.setEnabled(false, feature: LibraryFeature.manifest.id)
        await fixture.settle()
        let after = root.snapshot
        #expect(!after.rows.contains { $0.id.namespace == "book" })
        #expect(!after.sections.contains { $0.kind == .fallbacks })
        #expect(after.rows.allSatisfy { root.featureID(for: $0) == nil })
        #expect(after.emptyState?.title == "No Results" || !after.rows.isEmpty)

        // A query whose providers are still waiting drops them when their feature goes.
        await fixture.preferences.setEnabled(true, feature: SignalsFeature.manifest.id)
        await fixture.settle()
        let waiting = root.update(query: "zzqqxx")
        #expect(waiting.isLoading)
        await fixture.preferences.setEnabled(false, feature: SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(!root.snapshot.isLoading)
        root.end()
        await fixture.shutdown()
    }

    @Test func twoChangeSignalsAtOnceBothLand() async throws {
        let numbers = NumberedItems(count: 2)
        let fixture = await RootFixture.ready(extraSources: [numbers])
        let books = fixture.library.books
        books.rows.append(Row(id: ItemID("book", "5"), title: "Pottery Basics"))
        fixture.apps.rows.append(Row(id: ItemID("app", "com.example.potter"), title: "Potter"))
        // Two sources at once, and one source twice while its first load runs.
        books.signal.send()
        books.signal.send()
        let appsLoaded = fixture.root.slots.values.first { $0.source === fixture.apps }
        if let appsLoaded { fixture.root.load(appsLoaded) }
        books.rows.append(Row(id: ItemID("book", "6"), title: "Pottery Glazes"))
        books.signal.send()
        await fixture.settle()
        let titles = Set(fixture.results("pott"))
        #expect(titles.isSuperset(of: ["Pottery Basics", "Pottery Glazes", "Potter"]))
        await fixture.shutdown()
    }

    // MARK: Scale

    @Test func tenThousandRememberedRowsStayUsableAndAreTrimmed() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let fixture = await RootFixture.ready(storage: storage)
        let root = fixture.root
        let start = fixture.clock.now
        for index in 0..<10_000 {
            let row = Row(id: ItemID("note", "n\(index)"), title: "Note Number \(index)")
            _ = root.memory.remember(row, at: start.addingTimeInterval(Double(index)))
        }
        // Every save trims the set to the 1,800 most recent rows once it passes 2,000.
        await root.memory.drain()
        let kept = root.memory.rememberedIDs().count
        #expect(kept >= ItemMemory.maxRemembered * 9 / 10 && kept <= ItemMemory.maxRemembered)
        root.scheduleRebuild()
        await fixture.settle()
        #expect(root.catalogCount >= kept)
        _ = root.begin()
        let found = root.update(query: "note number 9999")
        #expect(found.rows.first?.title == "Note Number 9999")
        #expect(root.row(for: ItemID("note", "n0")) == nil)
        root.end()

        // The check asks the validator in batches of at most 200 and forgets what is gone.
        fixture.library.notes.deleted = [ItemID("note", "n9999")]
        root.validateRememberedRows()
        await fixture.settle()
        let batches = fixture.library.notes.checked.filter { !$0.isEmpty }
        #expect(batches.count >= kept / 200)
        #expect(batches.allSatisfy { $0.count <= 200 })
        #expect(root.row(for: ItemID("note", "n9999")) == nil)
        #expect(root.row(for: ItemID("note", "n9998"))?.title == "Note Number 9998")

        await root.flush()
        await fixture.shutdown()
        let again = await RootFixture.ready(storage: storage)
        #expect(again.root.memory.rememberedIDs().count == kept - 1)
        #expect(again.root.row(for: ItemID("note", "n9998")) != nil)
        await again.shutdown()
    }

    // MARK: Unicode

    @Test func unicodeQueriesFindTheirItemsWithValidHighlights() async throws {
        let titles = ["Café Crème", "日本語メモ", "😀 Smile Board", "שלום עולם", "مرحبا بالعالم", "Ünïcödé Tool"]
        let source = TitledItems(titles: titles)
        let fixture = await RootFixture.ready(extraSources: [source])
        let root = fixture.root
        _ = root.begin()
        let cases: [(query: String, title: String)] = [
            ("cafe", "Café Crème"), ("café", "Café Crème"), ("cafe\u{301}", "Café Crème"), ("CAFÉ CR", "Café Crème"),
            ("日本", "日本語メモ"), ("メモ", "日本語メモ"), ("😀", "😀 Smile Board"), ("smile", "😀 Smile Board"),
            ("שלו", "שלום עולם"), ("مرح", "مرحبا بالعالم"), ("unicode", "Ünïcödé Tool"),
        ]
        for (query, title) in cases {
            let snapshot = root.update(query: query)
            let row = snapshot.rows.first { $0.title == title }
            #expect(row != nil, "\(query) finds \(title)")
            if let row {
                let length = row.title.utf16.count
                #expect(row.titleHighlights.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= length })
                #expect(root.titleHighlights(for: row).allSatisfy { $0.upperBound <= length })
            }
        }
        // Odd input never breaks a keystroke.
        for odd in ["\u{3000}", "\u{200B}", "\u{301}", "🏳️‍🌈", String(repeating: "a", count: 400), "\u{0}x"] {
            _ = root.update(query: odd)
        }
        root.end()
        await fixture.shutdown()
    }
}

/// A catalog source over fixed titles.
final class TitledItems: CatalogSource {
    let namespace = "titled"
    let titles: [String]

    init(titles: [String]) {
        self.titles = titles
    }

    func rows() async throws -> [Row] {
        titles.enumerated().map { Row(id: ItemID("titled", "\($0.offset)"), title: $0.element) }
    }

    func actions(for row: Row) -> [Action] { [] }
}
