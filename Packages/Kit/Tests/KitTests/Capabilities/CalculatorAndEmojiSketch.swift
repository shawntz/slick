import Foundation
import Kit
import KitTesting
import Testing

/// Scenario 4, calculator: an instant provider that claims the top slot for a calculation, Tab puts
/// the answer in the search field (the row's completion), Return copies, and a history page.
final class CalculatorSketch: Feature, InstantProvider {
    static let manifest = FeatureManifest(
        id: "calculator", name: "Calculator", icon: .symbol("plus.forwardslash.minus"))

    private(set) var history: [(question: String, answer: String)] = []

    init(context: FeatureContext) {}

    let namespace = "calc"
    var liveProviders: [LiveProvider] { [.instant(self)] }

    /// Budget: 100 µs. A first-character check rejects most queries before any parsing.
    func answer(for query: String) -> InstantAnswer? {
        guard let first = query.first, first.isNumber else { return nil }
        let parts = query.split(separator: " ")
        guard parts.count == 3, let lhs = Double(parts[0]), let rhs = Double(parts[2]) else { return nil }
        let value: Double
        switch parts[1] {
        case "+": value = lhs + rhs
        case "*": value = lhs * rhs
        default: return nil
        }
        let answer = value.rounded() == value ? String(Int(value)) : String(value)
        // An answer to one query is not worth remembering in root search's catalog.
        let row = Row(
            id: ItemID(namespace, query), title: answer, subtitle: query, payload: Payload(query), completion: answer,
            memory: .never)
        return InstantAnswer(rows: [row], claimsTop: true)
    }

    /// The standard copy action, with the answer recorded in history once it ran.
    func actions(for row: Row) -> [Action] {
        let question = row.payload?.string ?? ""
        return [
            Action.copy(row.title, title: "Copy Answer", hud: "Copied \(row.title)").then { _ in
                self.history.insert((question, row.title), at: 0)
            }
        ]
    }

    var commands: [Command] {
        [
            Command(id: "history", title: "Calculator History") { _ in
                let rows = self.history.map {
                    Row(id: ItemID("calc", $0.question), title: $0.answer, subtitle: $0.question)
                }
                return .push(.list(ListPage(sections: [ListSection(rows: rows)]) { [.copy($0.title)] }))
            }
        ]
    }
}

/// Scenario 6, emoji: a grid with sections, a skin-tone setting, recents from usage tracking, and
/// paste as the primary action.
final class EmojiSketch: Feature {
    static let manifest = FeatureManifest(
        id: "emoji", name: "Emoji", icon: .glyph("😀"),
        permissions: [PermissionNeed(.accessibility, reason: "Paste the chosen emoji into the frontmost app.")])
    nonisolated static let skinTone = SettingKey("skinTone", default: SkinTone.none)

    nonisolated enum SkinTone: String, CaseIterable, SettingValue {
        case none, medium
        var modifier: String { self == .medium ? "\u{1F3FD}" : "" }
    }

    static let catalog: [(section: String, glyph: String, name: String, takesTone: Bool)] = [
        ("Smileys", "😀", "Grinning Face", false), ("Smileys", "😂", "Tears of Joy", false),
        ("People", "👍", "Thumbs Up", true), ("Animals", "🐢", "Turtle", false),
    ]

    let context: FeatureContext

    init(context: FeatureContext) {
        self.context = context
    }

    var commands: [Command] {
        [
            Command(id: "search", title: "Search Emoji") { _ in
                .push(.grid(GridPage(EmojiGrid(feature: self), columns: 8)))
            }
        ]
    }

    var settingsPane: SettingsPane? {
        SettingsPane(items: [.picker("Skin tone", key: Self.skinTone) { $0.rawValue.capitalized }])
    }
}

final class EmojiGrid: ListSource {
    private unowned let feature: EmojiSketch

    init(feature: EmojiSketch) {
        self.feature = feature
    }

    /// An open grid redraws when the skin tone changes.
    var reloadsOnSettings: [AnySettingKey] { [EmojiSketch.skinTone.erased] }

    /// Recent rows come back as snapshots from usage. The Recent section hides while searching, so
    /// host filtering never shows a row twice; recency orders matches inside a tier.
    func load(_ request: ListRequest) async throws -> ListResult {
        let tone = feature.context.settings[EmojiSketch.skinTone].modifier
        let usage = feature.context.usage
        let frecency = usage.frecency(namespace: "emoji")
        let rows = EmojiSketch.catalog.map { emoji in
            let glyph = emoji.glyph + (emoji.takesTone ? tone : "")
            let id = ItemID("emoji", glyph)
            return (emoji.section, Row(id: id, title: emoji.name, icon: .glyph(glyph), rankHint: frecency[id] ?? 0))
        }
        let recent = usage.recentlyUsed(namespace: "emoji", limit: 8).compactMap(\.snapshot)
        let sections = ["Smileys", "People", "Animals"].map { name in
            ListSection(name, rows: rows.filter { $0.0 == name }.map(\.1))
        }
        return ListResult(
            sections: [ListSection("Recent", visibility: .whenQueryEmpty, rows: recent)] + sections)
    }

    func actions(for row: Row) -> [Action] {
        [.paste(row.id.key, title: "Paste Emoji").recordingUse(), .copy(row.id.key).recordingUse()]
    }
}

@Suite("Scenario: calculator and emoji")
struct CalculatorAndEmojiSketchTests {
    @Test func calculatorClaimsTheTopAndCompletesWithTab() async throws {
        let harness = FeatureHarness(CalculatorSketch.self)
        #expect(harness.issues.isEmpty)
        #expect(harness.instantAnswers(for: "safari").isEmpty)
        let answer = try #require(harness.instantAnswers(for: "12 * 3").first)
        #expect(answer.claimsTop)
        #expect(answer.rows.map(\.completion) == ["36"])
        #expect(try await harness.pressTab("12 * 3", on: answer.rows[0]) == "36")
        try await harness.performRoot("copy", on: answer.rows[0], query: "12 * 3")
        #expect(harness.fakes.pasteboard.copiedTexts == ["36"])
        #expect(harness.huds == ["Copied 36"])
        try await harness.run("history")
        #expect(harness.rows.map(\.subtitle) == ["12 * 3"])
    }

    @Test func emojiGridPastesWithTheSkinToneAndRemembersRecents() async throws {
        let harness = FeatureHarness(EmojiSketch.self)
        #expect(harness.issues.isEmpty)
        try await harness.run("search")
        #expect(harness.sections.map(\.title) == ["Smileys", "People", "Animals"], "an empty Recent is hidden")
        harness.context.settings[EmojiSketch.skinTone] = .medium
        try await harness.settle()
        try await harness.setQuery("thumbs")
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["👍\u{1F3FD}"], "the open grid took the new tone")
        try await harness.run("search")
        #expect(harness.sections.first?.title == "Recent")
        #expect(harness.sections.first?.rows.map(\.title) == ["Thumbs Up"])
        try await harness.setQuery("t")
        #expect(harness.sections.map(\.title) == ["Smileys", "People", "Animals"], "Recent hides while searching")
        #expect(harness.sections[0].rows.map(\.title) == ["Tears of Joy"])
        #expect(harness.sections[1].rows.map(\.title) == ["Thumbs Up"])
        let paste = try #require(harness.actions().first)
        try await harness.perform(paste, row: harness.selectedRow, launch: .root)
        #expect(harness.fakes.usage.recorded.count == 1, "root records its own uses; the action does not")
    }
}
