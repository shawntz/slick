import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// The Color History page on the fake clock, Saturday 14 November 2026, 09:30 UTC.
@Suite("Color History", .timeLimit(.minutes(1)))
struct HistoryTests {
    /// Adds colors one minute apart, oldest first.
    private func add(_ hexes: [String], to harness: FeatureHarness<ColorsFeature>) async throws {
        for hex in hexes {
            harness.fakes.clock.advance(by: .seconds(60))
            await harness.feature.history.add(try color(hex), source: .picked)
        }
    }

    private func entry(_ hex: String, in harness: FeatureHarness<ColorsFeature>) throws -> ColorEntry {
        try #require(harness.feature.history.entries.first { ColorFormatter().hex($0.color) == hex })
    }

    @Test func pinnedFirstThenByDayNewestFirst() async throws {
        let harness = await readyHarness()
        try await add(["#111111", "#222222"], to: harness)
        harness.fakes.clock.advance(by: .seconds(24 * 3600))
        try await add(["#333333", "#444444"], to: harness)
        await harness.feature.history.setPinned(try entry("#222222", in: harness).id, true)
        try await harness.run("history")
        #expect(harness.sections.map(\.title) == ["Pinned", "Today", "Yesterday"])
        #expect(harness.sections.map { $0.rows.map(\.title) } == [["#222222"], ["#444444", "#333333"], ["#111111"]])
        let row = try #require(harness.selectedRow)
        #expect(row.title == "#222222" && row.subtitle == "rgb(34 34 34)")
        #expect(row.icon == .color(try color("#222222").kitColor))
        #expect(row.memory == .never)
        #expect(harness.issues.isEmpty && harness.pendingIssues.isEmpty)
    }

    @Test func theDetailShowsTheColorEveryFormatAndItsContrast() async throws {
        let harness = await readyHarness()
        try await add(["#663399"], to: harness)
        try await harness.run("history")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == .color(.rgba(red: 0.4, green: 0.2, blue: 0.6, alpha: 1)))
        let labels = detail.metadata.compactMap { item -> String? in
            if case .label(let label, let value, _) = item { return "\(label): \(value)" }
            return nil
        }
        #expect(
            labels == [
                "Hex: #663399", "RGB: rgb(102 51 153)", "HSL: hsl(270 50% 40%)", "HSB: hsb(270 66.7% 60%)",
                "HWB: hwb(270 20% 40%)", "OKLCH: oklch(44.03% 0.1603 303.37)",
                "SwiftUI: Color(red: 0.4, green: 0.2, blue: 0.6)",
                "AppKit: NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1)",
                "CSS Variable: --color-663399: #663399;", "CSS Name: rebeccapurple", "Contrast on White: 8.4:1",
                "Contrast on Black: 2.49:1", "Source: Picked on screen",
            ])
        #expect(
            detail.metadata.contains(
                .tags("WCAG on White", [Tag("Normal Text AAA", color: .green), Tag("Large Text AAA", color: .green)])))
        #expect(
            detail.metadata.contains(
                .tags("WCAG on Black", [Tag("Normal Text Fails", color: .red), Tag("Large Text Fails", color: .red)])))
        #expect(detail.metadata.contains(.date("Added", harness.fakes.clock.now)))
    }

    @Test func copyAndPasteFromTheHistoryInEveryFormat() async throws {
        let harness = await readyHarness()
        try await add(["#663399", "#00FF00"], to: harness)
        try await harness.run("history")
        try harness.select(title: "#663399")
        let actions = harness.actions()
        #expect(
            actions.map(\.title) == [
                "Copy as Hex", "Paste as Hex", "Show in Large Type", "Copy as RGB", "Copy as HSL", "Copy as HSB",
                "Copy as HWB", "Copy as OKLCH", "Copy as SwiftUI", "Copy as AppKit", "Copy as CSS Variable",
                "Pin Color", "Name This Color", "Delete Color", "Clear History",
            ])
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.copiedTexts == ["#663399"])
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["#663399"])
        try await harness.perform("copy-swiftUI")
        #expect(harness.fakes.pasteboard.copiedTexts.last == "Color(red: 0.4, green: 0.2, blue: 0.6)")
        #expect(harness.historyHexes == ["#00FF00", "#663399"], "copying from the history moves nothing")
        #expect(harness.issues.isEmpty)
    }

    @Test func pinAndUnpin() async throws {
        let harness = await readyHarness()
        try await add(["#111111", "#222222"], to: harness)
        try await harness.run("history")
        try harness.select(title: "#111111")
        let pin = try #require(harness.actions().first { $0.id == "pin" })
        #expect(pin.shortcut == .pin)
        try await harness.perform("pin")
        #expect(harness.toasts.last?.title == "Pinned #111111")
        #expect(harness.sections.first?.title == "Pinned")
        #expect(harness.sections.first?.rows.map(\.title) == ["#111111"])
        try harness.select(title: "#111111")
        try await harness.perform("unpin")
        #expect(harness.toasts.last?.title == "Unpinned #111111")
        #expect(!harness.sections.contains { $0.title == "Pinned" })
    }

    @Test func nameThisColor() async throws {
        let harness = await readyHarness()
        try await add(["#663399"], to: harness)
        try await harness.run("history")
        let outcome = try await harness.perform("rename")
        #expect(outcome.kind == .push)
        try harness.fill("name", text: "  Brand Purple  ")
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Saved Name")
        #expect(harness.rows.map(\.title) == ["Brand Purple"])
        #expect(harness.rows.first?.subtitle == "#663399")
        try await harness.setQuery("brand")
        #expect(harness.rows.map(\.title) == ["Brand Purple"])
        try await harness.setQuery("")
        try harness.select(title: "Brand Purple")
        try await harness.perform("copy-cssVariable")
        #expect(harness.fakes.pasteboard.copiedTexts == ["--brand-purple: #663399;"])

        // The same color picked again keeps its name.
        await harness.feature.history.add(try color("#663399"), source: .picked)
        #expect(harness.feature.history.entries.first?.name == "Brand Purple")

        // An empty name, or one that shows nothing, removes it.
        try await harness.run("history")
        try await harness.perform("rename")
        try harness.fill("name", text: "\u{200B}")
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Removed Name")
        #expect(harness.feature.history.entries.first?.name == nil)
    }

    @Test func aNameIsCheckedAndShownOnOneLine() async throws {
        let harness = await readyHarness()
        try await add(["#663399"], to: harness)
        try await harness.run("history")
        try await harness.perform("rename")
        try harness.fill("name", text: String(repeating: "x", count: 61))
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        #expect(harness.page?.formErrors["name"]?.message == "Use 60 characters or fewer.")
        try harness.fill("name", text: "Line\nBreak \u{202E}desrever")
        try await harness.submit()
        #expect(harness.feature.history.entries.first?.name == "Line Break \u{FFFD}desrever")
        #expect(harness.issues.isEmpty)
    }

    @Test func deleteAsksAndNamesTheColor() async throws {
        let harness = await readyHarness()
        try await add(["#111111", "#663399"], to: harness)
        await harness.feature.history.rename(try entry("#663399", in: harness).id, to: "Brand Purple")
        try await harness.run("history")
        try harness.select(title: "Brand Purple")
        harness.confirmationAnswer = false
        try await harness.perform("delete")
        #expect(harness.confirmations.map(\.title) == ["Delete “Brand Purple” from History?"])
        #expect(harness.confirmations.first?.isDestructive == true)
        #expect(harness.feature.history.entries.count == 2)
        harness.confirmationAnswer = true
        try await harness.perform("delete")
        #expect(harness.historyHexes == ["#111111"])
        #expect(harness.rows.map(\.title) == ["#111111"])
        #expect(harness.toasts.last?.title == "Deleted Color")
    }

    @Test func clearHistoryAsksAndKeepsPinnedColors() async throws {
        let harness = await readyHarness()
        try await add(["#111111", "#222222", "#333333"], to: harness)
        await harness.feature.history.setPinned(try entry("#222222", in: harness).id, true)
        try await harness.run("history")
        harness.confirmationAnswer = false
        try await harness.perform("clear-history")
        #expect(harness.confirmations.map(\.title) == ["Clear Color History?"])
        #expect(harness.feature.history.entries.count == 3)
        harness.confirmationAnswer = true
        try await harness.perform("clear-history")
        #expect(harness.historyHexes == ["#222222"])
        #expect(harness.toasts.last?.title == "Cleared Color History")

        try await add(["#444444"], to: harness)
        try await harness.pressSettingsButton("Clear History")
        #expect(harness.historyHexes == ["#222222"])
        #expect(harness.confirmations.count == 3)
    }

    @Test func aSmallerLimitAsksFirstThenKeepsTheNewestAndEveryPin() async throws {
        let harness = await readyHarness()
        for n in 0..<30 {
            harness.fakes.clock.advance(by: .seconds(1))
            await harness.feature.history.add(ColorValue(bytes: n, 0, 0), source: .picked)
        }
        await harness.feature.history.setPinned(try entry("#000000", in: harness).id, true)
        harness.confirmationAnswer = false
        #expect(try harness.chooseSetting("Keep at most", option: "25 Colors") == false)
        try await harness.settle()
        #expect(harness.confirmations.map(\.title) == ["Keep Only 25 Colors?"])
        #expect(harness.feature.history.entries.count == 30, "a declined question deletes nothing")

        harness.confirmationAnswer = true
        #expect(try harness.chooseSetting("Keep at most", option: "25 Colors"))
        try await harness.settle()
        let entries = harness.feature.history.entries
        #expect(entries.count == 26, "25 colors and the pin")
        #expect(entries.contains { $0.isPinned && ColorFormatter().hex($0.color) == "#000000" })
        #expect(ColorFormatter().hex(try #require(entries.first).color) == "#1D0000", "the newest stays")
        #expect(!entries.contains { ColorFormatter().hex($0.color) == "#040000" }, "the oldest went")

        #expect(try harness.chooseSetting("Keep at most", option: "250 Colors"))
        #expect(harness.confirmations.count == 2, "a larger size asks nothing")

        // Unpinning deletes nothing at once, even with the history full.
        harness.context.settings[ColorSettings.historyLimit] = 25
        try await harness.settle()
        await harness.feature.history.setPinned(try entry("#000000", in: harness).id, false)
        #expect(harness.feature.history.entries.count == 26)
        await harness.feature.history.setPinned(try entry("#000000", in: harness).id, true)

        // New colors past the limit push the oldest out.
        harness.context.settings[ColorSettings.historyLimit] = 25
        try await harness.settle()
        await harness.feature.history.add(ColorValue(bytes: 0, 255, 0), source: .picked)
        #expect(harness.feature.history.entries.count == 26)
    }

    @Test func theFileHoldsTheHistoryAcrossLaunches() async throws {
        let fakes = FakeServices()
        let harness = await readyHarness(fakes: fakes)
        try await add(["#111111", "#663399"], to: harness)
        await harness.feature.history.rename(try entry("#663399", in: harness).id, to: "Brand Purple")
        await harness.feature.history.setPinned(try entry("#111111", in: harness).id, true)
        let text = try String(contentsOf: harness.historyFile, encoding: .utf8)
        #expect(text.contains("\"version\" : 1") && text.contains("Brand Purple"))

        let next = await readyHarness(fakes: fakes)
        #expect(next.feature.history.entries == harness.feature.history.entries)
        #expect(next.feature.history.pinned.map(\.name) == [nil])
    }

    @Test func aDamagedFileIsSetAsideAndANewHistoryStarts() async throws {
        let fakes = FakeServices()
        try writeHistory("{ not json", in: fakes)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.isEmpty)
        let aside = fakes.storage.dataDirectory(for: "colors").appending(path: "history-damaged-1.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
        try await add(["#663399"], to: harness)
        #expect(FileManager.default.fileExists(atPath: harness.historyFile.path))
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json", "the damaged file is kept")
    }

    @Test func aFileFromANewerVersionIsShownButNeverOverwritten() async throws {
        let fakes = FakeServices()
        let newer = """
            {
              "version" : 2,
              "palettes" : ["web"],
              "entries" : [
                {
                  "id" : "00000000-0000-0000-0000-000000000001",
                  "color" : { "red" : 0.4, "green" : 0.2, "blue" : 0.6, "alpha" : 1, "space" : "p3" },
                  "date" : "2026-11-14T09:00:00.000Z",
                  "source" : "imported",
                  "isPinned" : true
                }
              ]
            }
            """
        try writeHistory(newer, in: fakes)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.isReadOnly)
        #expect(harness.feature.status?.title == "Color History Is Read Only")
        #expect(harness.historyHexes == ["#663399"])
        #expect(harness.feature.history.entries.first?.isPinned == true)
        #expect(harness.feature.history.entries.first?.source == .picked, "an unknown source reads as picked")
        try await add(["#111111"], to: harness)
        #expect(harness.historyHexes == ["#111111", "#663399"], "shown for the session")
        #expect(try String(contentsOf: harness.historyFile, encoding: .utf8) == newer, "never saved over")
    }

    @Test func aHandEditedFileIsMadeSafeToShow() async throws {
        let fakes = FakeServices()
        try writeHistory(
            """
            { "version" : 1, "entries" : [
              { "id" : "00000000-0000-0000-0000-000000000001", "color" : { "red" : 1, "green" : 0, "blue" : 0, "alpha" : 1 },
                "date" : "2026-11-14T09:00:00Z", "name" : "Line\\nBreak" },
              { "id" : "00000000-0000-0000-0000-000000000001", "color" : { "red" : 0, "green" : 1, "blue" : 0, "alpha" : 1 },
                "date" : "2026-11-14T08:00:00Z" },
              { "id" : "00000000-0000-0000-0000-000000000002", "color" : { "red" : 900, "green" : -5, "blue" : 0, "alpha" : 7 },
                "date" : "2026-11-14T07:00:00Z", "name" : "\\u200b\\u202e" }
            ] }
            """, in: fakes)
        let harness = await readyHarness(fakes: fakes)
        let entries = harness.feature.history.entries
        #expect(entries.count == 2, "a repeated ID is kept once")
        #expect(entries[0].name == "Line Break")
        #expect(entries[1].name == nil, "a name that shows nothing is dropped")
        #expect(entries[1].color == ColorValue(red: 2, green: -1, blue: 0, alpha: 1), "components are bounded")
        try await harness.run("history")
        #expect(harness.rows.allSatisfy { !$0.title.contains("\n") && !$0.title.isEmpty })
    }

    @Test func aStaleRowOnlyCopies() async throws {
        let harness = await readyHarness()
        try await add(["#663399"], to: harness)
        try await harness.run("history")
        let row = try #require(harness.selectedRow)
        await harness.feature.history.delete(try entry("#663399", in: harness).id)
        let actions = harness.feature.historyList.actions(for: row)
        #expect(actions.map(\.id).allSatisfy { $0.hasPrefix("copy-") || $0 == "paste" || $0 == "large-type" })
        #expect(!actions.isEmpty)
    }

    @Test func searchFindsHexNamesAndCSSNames() async throws {
        let harness = await readyHarness()
        try await add(["#663399", "#D2B48C", "#123456"], to: harness)
        try await harness.run("history")
        try await harness.setQuery("rebeccapurple")
        #expect(harness.rows.map(\.title) == ["#663399"])
        try await harness.setQuery("123456")
        #expect(harness.rows.map(\.title) == ["#123456"])
        try await harness.setQuery("tan")
        #expect(harness.rows.map(\.title) == ["#D2B48C"])
    }

    @Test func anEmptyHistoryOffersPickColor() async throws {
        let harness = await readyHarness()
        try await harness.run("history")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Colors Yet")
        #expect(harness.actions().map(\.id) == ["run.cmd:colors.pick"])
    }

    @Test func anOpenHistoryFollowsTheFormatSettings() async throws {
        let harness = await readyHarness()
        try await add(["#66CC99"], to: harness)
        try await harness.run("history")
        #expect(harness.rows.first?.subtitle == "rgb(102 204 153)")
        harness.context.settings[ColorSettings.defaultFormat] = .hsl
        harness.context.settings[ColorSettings.hexCase] = .lowercase
        try await harness.settle()
        #expect(harness.rows.first?.title == "#66cc99")
        #expect(harness.rows.first?.subtitle == "hsl(150 50% 60%)")
    }
}
