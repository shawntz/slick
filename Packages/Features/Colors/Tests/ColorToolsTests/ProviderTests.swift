import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// Typing a color, or contrast and two colors, in root search.
@Suite("Typed colors", .timeLimit(.minutes(1)))
struct ProviderTests {
    @Test func aTypedColorClaimsTheTopWithItsSwatchAndConversions() async throws {
        let harness = await readyHarness()
        let answer = try #require(harness.instantAnswers(for: "#663399").first)
        #expect(answer.claimsTop)
        let row = try #require(answer.rows.first)
        #expect(answer.rows.count == 1)
        #expect(row.title == "#663399")
        #expect(row.subtitle == "rgb(102 51 153)  ·  hsl(270 50% 40%)  ·  oklch(44.03% 0.1603 303.37)")
        #expect(row.icon == .color(.rgba(red: 0.4, green: 0.2, blue: 0.6, alpha: 1)))
        #expect(row.memory == .never, "root search keeps nothing of it")
        #expect(row.completion == "#663399")
        #expect(row.id.namespace == "colors")
        #expect(harness.issues.isEmpty && harness.pendingIssues.isEmpty)
    }

    @Test func everyFormTheBriefNamesConverts() async throws {
        let harness = await readyHarness()
        let queries = [
            "#639", "#6398", "#663399", "#66339980", "rgb(102, 51, 153)", "rgb(102 51 153)", "rgba(102, 51, 153, 0.5)",
            "rgba(102 51 153 / 50%)", "hsl(270, 50%, 40%)", "hsl(270 50% 40%)", "hsla(270, 50%, 40%, 0.5)",
            "hsla(270 50% 40% / 0.5)", "hwb(270 20% 40%)", "hwb(270, 20%, 40%)", "oklch(44.03% 0.1603 303.37)",
            "oklch(0.4403, 0.1603, 303.37)", "color rebeccapurple", "Color RebeccaPurple", "color #663399",
        ]
        for query in queries {
            let row = harness.answerRow(query)
            #expect(row?.title.hasPrefix("#663399") == true, "\(query): \(row?.title ?? "nil")")
        }
    }

    @Test func namesConvertOnlyBehindTheKeyword() async throws {
        let harness = await readyHarness()
        for word in [
            "red", "tan", "navy", "orange", "chocolate", "coral", "rebeccapurple", "color", "color ", "colors",
        ] {
            #expect(harness.answerRow(word) == nil, "\(word)")
        }
        #expect(harness.answerRow("color tan")?.title == "#D2B48C")
        #expect(harness.answerRow("color notacolor") == nil)
    }

    @Test func returnCopiesTheDefaultFormatAndKeepsTheColor() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("hsl(270 50% 40%)"))
        let actions = harness.rootActions(for: row)
        #expect(actions.primary?.title == "Copy as Hex")
        #expect(actions.secondary?.title == "Paste as Hex")
        #expect(actions.map(\.id).contains("run.cmd:colors.history"))
        let largeType = try #require(actions.first { $0.id == "large-type" })
        #expect(largeType.shortcut == .largeType)
        let shown = try await harness.performRoot("large-type", on: row, query: "hsl(270 50% 40%)")
        guard case .showLargeType(let text) = shown else {
            Issue.record("Show in Large Type gave \(shown)")
            return
        }
        #expect(text == "#663399", "Large Type shows the value Return copies")
        #expect(harness.historyHexes.isEmpty, "showing a color keeps nothing")
        try await harness.performRoot(try #require(actions.primary?.id), on: row, query: "hsl(270 50% 40%)")
        #expect(harness.fakes.pasteboard.copiedTexts == ["#663399"])
        #expect(harness.huds == ["Copied #663399"])
        #expect(harness.historyHexes == ["#663399"], "a copied color joins the history")
        #expect(harness.feature.history.entries.first?.source == .typed)
        #expect(harness.issues.isEmpty)
    }

    @Test func pasteAndTheOtherFormatsWork() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("#663399"))
        try await harness.performRoot("paste", on: row)
        #expect(harness.fakes.pasteboard.pastedTexts == ["#663399"])
        let expected: [String: String] = [
            "copy-rgb": "rgb(102 51 153)", "copy-hsl": "hsl(270 50% 40%)", "copy-hsb": "hsb(270 66.7% 60%)",
            "copy-hwb": "hwb(270 20% 40%)", "copy-oklch": "oklch(44.03% 0.1603 303.37)",
            "copy-swiftUI": "Color(red: 0.4, green: 0.2, blue: 0.6)",
            "copy-appKit": "NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1)",
            "copy-cssVariable": "--color-663399: #663399;",
        ]
        for (id, text) in expected.sorted(by: { $0.key < $1.key }) {
            try await harness.performRoot(id, on: row)
            #expect(harness.fakes.pasteboard.copiedTexts.last == text, "\(id)")
        }
        #expect(harness.historyHexes == ["#663399"], "one color, kept once")
    }

    @Test func theDefaultFormatAndHexCaseFollowSettings() async throws {
        let harness = await readyHarness()
        harness.context.settings[ColorSettings.defaultFormat] = .oklch
        harness.context.settings[ColorSettings.hexCase] = .lowercase
        let row = try #require(harness.answerRow("#66CC99"))
        #expect(row.title.hasPrefix("oklch("))
        #expect(row.subtitle?.hasPrefix("#66cc99") == true)
        let actions = harness.rootActions(for: row)
        #expect(actions.primary?.title == "Copy as OKLCH")
        #expect(actions.secondary?.title == "Paste as OKLCH")
        #expect(!actions.contains { $0.id == "copy-hex" && $0.section == nil }, "hex moves to Other Formats")
    }

    @Test func aColorOutsideSRGBSaysSo() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("oklch(70% 0.4 30)"))
        #expect(row.accessories.contains(.tag("Outside sRGB", color: .orange)))
        #expect(harness.answerRow("#663399")?.accessories.isEmpty == true)
    }

    @Test func contrastAnswersWithTheRatioAndTheVerdicts() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("contrast #767676 #FFFFFF"))
        #expect(row.title == "4.54:1")
        #expect(row.subtitle == "#767676 on #FFFFFF")
        #expect(row.accessories == [.tag("Normal Text AA", color: .green), .tag("Large Text AAA", color: .green)])
        #expect(row.memory == .never)
        for query in [
            "contrast black white", "contrast black on white", "contrast #000, #fff",
            "Contrast rgb(0 0 0) vs hsl(0 0% 100%)",
            "contrast rgb(0, 0, 0) against white",
        ] {
            #expect(harness.answerRow(query)?.title == "21:1", "\(query)")
        }
        let failing = try #require(harness.answerRow("contrast #777 white"))
        #expect(failing.accessories.first == .tag("Normal Text Fails", color: .red))
        for query in ["contrast", "contrast #000", "contrast #000 #fff #888", "contrast ratio", "contrast (#000 #fff"] {
            #expect(harness.answerRow(query) == nil, "\(query)")
        }

        let actions = harness.rootActions(for: row)
        #expect(actions.map(\.id) == ["copy-ratio", "copy-result"])
        try await harness.performRoot("copy-result", on: row)
        #expect(harness.fakes.pasteboard.copiedTexts == ["4.54:1, AA for normal text, AAA for large text"])
        #expect(harness.feature.history.entries.isEmpty, "contrast keeps no color")
    }

    @Test func theSettingTurnsTypedColorsOff() async throws {
        let harness = await readyHarness()
        harness.context.settings[ColorSettings.convertsTypedColors] = false
        #expect(harness.answerRow("#663399") == nil)
        #expect(harness.answerRow("contrast black white") == nil)
    }

    @Test func foreignQueriesAreRefusedFromTheirFirstBytes() {
        let foreign = [
            "safari", "terminal", "calendar", "chrome", "code", "hello world", "rgb", "rgbx(1 2 3)", "hsv(1 2 3)",
            "oklab(1 2 3)", "colour red", "contrasts", "こんにちは", "Ｒｇｂ(1 2 3)", "＃fff", " #fff", "",
        ]
        for query in foreign {
            let bytes = CountingBytes(query)
            #expect(ColorQuery.kind(of: bytes) == nil, "\(query)")
            #expect(bytes.reads.furthest < ColorQuery.longestOpening, "\(query) read \(bytes.reads.furthest + 1) bytes")
        }
        // Most text is refused on its first byte.
        for query in ["safari", "terminal", "xcode", "1 + 1", "~/Documents", "/usr", ":smile"] {
            let bytes = CountingBytes(query)
            #expect(ColorQuery.kind(of: bytes) == nil)
            #expect(bytes.reads.furthest == 0, "\(query)")
        }
        // A long paste that starts like a color is decided from its start, and then refused by length.
        let pasted = "rgb(" + String(repeating: "1 ", count: 10_000) + ")"
        let bytes = CountingBytes(pasted)
        #expect(ColorQuery.kind(of: bytes) == .function)
        #expect(bytes.reads.furthest < ColorQuery.longestOpening)
        #expect(ColorQuery.parse(pasted, kind: .function) == nil)
    }

    @Test func oddTextIsRefused() async throws {
        let harness = await readyHarness()
        let odd = [
            "#", "#\u{0}ff", "#fff\n", "rgb(1 2 3)\u{202E}", "color \u{202E}red", "color red\u{0}",
            "rgb(1 2 3)\nrgb(1 2 3)",
            "color " + String(repeating: "a", count: 300), "contrast " + String(repeating: "(", count: 300),
            "hsl(270 50% 40%) and more", "#fff #000",
        ]
        for query in odd {
            #expect(harness.answerRow(query) == nil, "\(query.debugDescription)")
        }
    }

    @Test func actionsWorkFromARowRebuiltFromItsSnapshot() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("#663399"))
        let data = try JSONEncoder().encode(row)
        let rebuilt = try JSONDecoder().decode(Row.self, from: data)
        try await harness.performRoot("copy-rgb", on: rebuilt)
        #expect(harness.fakes.pasteboard.copiedTexts == ["rgb(102 51 153)"])
        let contrast = try #require(harness.answerRow("contrast black white"))
        let again = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(contrast))
        #expect(harness.rootActions(for: again).map(\.id) == ["copy-ratio", "copy-result"])
    }
}
