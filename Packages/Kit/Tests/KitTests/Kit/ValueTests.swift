import Foundation
import Kit
import Testing

@Suite("Values")
struct ValueTests {
    @Test func parsesAndPrintsHexColors() throws {
        let orange = try #require(KitColor(hex: "#FF8800"))
        #expect(orange.hexString == "#FF8800")
        #expect(KitColor(hex: "f80")?.hexString == "#FF8800")
        #expect(KitColor(hex: "#FF880080")?.hexString == "#FF880080")
        #expect(KitColor(hex: "#12") == nil)
        #expect(KitColor(hex: "#GGGGGG") == nil)
        #expect(KitColor.red.hexString == nil)
    }

    @Test func payloadsHoldStringsOrValues() throws {
        let text = Payload("/tmp/a.txt")
        #expect(text.string == "/tmp/a.txt")
        #expect(try text.decode(String.self) == "/tmp/a.txt")
        #expect(throws: DecodingError.self) { try text.decode(Int.self) }

        let location = Location(line: 3, path: "/tmp/b.txt")
        let value = Payload(location)
        #expect(value.string == nil)
        #expect(try value.decode(Location.self) == location)
        #expect(throws: DecodingError.self) { try value.decode(String.self) }
    }

    @Test func aValuePayloadDecodesFromItsSnapshotAndStaysEqual() throws {
        let payload = Payload(Location(line: 7, path: "/tmp/d.txt"))
        let snapshot = try JSONDecoder().decode(Payload.self, from: try JSONEncoder().encode(payload))
        #expect(try snapshot.decode(Location.self) == Location(line: 7, path: "/tmp/d.txt"))
        #expect(snapshot == payload)
        #expect(snapshot.hashValue == payload.hashValue)
        #expect(Payload(Location(line: 8, path: "/tmp/d.txt")) != payload)
        #expect(Payload("x") != payload)
    }

    @Test func rowsSurviveASnapshotWithoutTheirHighlights() throws {
        let row = Row(
            id: ItemID("file", "/tmp/c.txt"), title: "c.txt", subtitle: "/tmp",
            icon: .adaptive(light: .glyph("A"), dark: .glyph("B")),
            accessories: [.tag("New", color: .green), .date(Date(timeIntervalSince1970: 0)), .shortcut(.open)],
            keywords: ["text"], payload: Payload(["kind": "text"]), completion: "/tmp/c.txt",
            quickLookURL: URL(filePath: "/tmp/c.txt"),
            alternates: [Row.Alternate(modifiers: .command, subtitle: "Reveal")], titleHighlights: [0..<1],
            rankHint: 2, memory: .learnOnly, expires: Date(timeIntervalSince1970: 60),
            represents: .files([URL(filePath: "/tmp/c.txt")]))
        let decoded = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(row))
        var expected = row
        expected.titleHighlights = []
        #expect(decoded == expected)
        #expect(decoded.alternate(for: .command)?.subtitle == "Reveal")
        #expect(decoded.alternate(for: [.command, .shift]) == nil)
    }

    @Test func aMinimalSnapshotDecodesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(Row.self, from: Data(#"{"id":"note:1","title":"One"}"#.utf8))
        #expect(decoded == Row(id: ItemID("note", "1"), title: "One"))
        #expect(decoded.memory == .remember)
    }

    @Test func sectionsShowByWhetherTheUserSearches() {
        let recent = ListSection("Recent", visibility: .whenQueryEmpty, rows: [])
        let results = ListSection("Results", visibility: .whenSearching, rows: [])
        #expect(recent.isVisible(forQuery: "") && !recent.isVisible(forQuery: "a"))
        #expect(!results.isVisible(forQuery: "") && results.isVisible(forQuery: "a"))
        #expect(ListSection(rows: []).isVisible(forQuery: "a"))
    }

    @Test func suggestionsAreImminentInsideTheirWindow() {
        let start = Date(timeIntervalSince1970: 1000)
        let row = Row(id: ItemID("event", "1"), title: "Standup")
        let suggestion = Suggestion(
            id: "1", row: row, urgency: .constant(1), expires: start + 600, imminentFrom: start + 300)
        #expect(!suggestion.isImminent(at: start))
        #expect(suggestion.isImminent(at: start + 300))
        #expect(!suggestion.isImminent(at: start + 600))
        #expect(!Suggestion(id: "2", row: row, urgency: .constant(1), expires: start + 600).isImminent(at: start))
    }

    @Test func detailUpdatesBuildTheDetail() {
        var detail = Detail()
        detail.apply(.append("Hello"))
        detail.apply(.append(", world"))
        #expect(detail.body == .markdown("Hello, world"))
        detail.apply(.metadata([.label("Model", value: "Test")]))
        detail.apply(.replace(Detail(.text("out", monospaced: true))))
        detail.apply(.append("put"))
        #expect(detail == Detail(.text("output", monospaced: true)))
    }

    @Test func urgencyFollowsItsShape() {
        let start = Date(timeIntervalSince1970: 1000)
        let ramp = Urgency.ramp(start: start, full: start + 600, end: start + 1500)
        #expect(ramp.value(at: start - 1) == 0)
        #expect(ramp.value(at: start + 300) == 0.5)
        #expect(ramp.value(at: start + 1000) == 1)
        #expect(ramp.value(at: start + 1501) == 0)
        let decay = Urgency.decay(since: start, timeConstant: .seconds(600))
        #expect(abs(decay.value(at: start + 120) - 0.8187) < 0.0001)
        #expect(decay.value(at: start - 60) == 1)
        #expect(Urgency.constant(3).value(at: start) == 1)
        #expect(AcceptancePrior(accepts: 4, rejects: 1).mean == 0.8)
    }

    @Test func selectionsReadAsText() throws {
        #expect(Selection.files([URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")]).text == "/tmp/a\n/tmp/b")
        #expect(Selection.url(try #require(URL(string: "https://example.com"))).kind == .url)
    }

    @Test func formsReportRequiredFields() {
        let form = FormPage(
            title: "New",
            fields: [
                .text("name", title: "Name", isRequired: true),
                .checkbox("on", title: "On", label: "On", initial: true),
                .files("files", title: "Files", isRequired: true), .description("Static"),
            ]
        ) { _, _ in .pop }
        var values = form.initialValues
        #expect(values.bool("on"))
        #expect(form.missingRequiredFields(in: values) == ["name": "Required", "files": "Required"])
        #expect(
            FormPage(title: "Tags", fields: [.tags("tags", title: "Tags", initial: ["a"])]) { _, _ in .pop }
                .initialValues.strings("tags") == ["a"])
        values["name"] = .text("  x ")
        values["files"] = .files([URL(filePath: "/tmp/a")])
        #expect(form.missingRequiredFields(in: values).isEmpty)
    }
}

/// A payload value for the tests.
private nonisolated struct Location: Codable, Hashable, Sendable {
    var line: Int
    var path: String
}
