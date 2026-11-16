import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// A second engineer's attempts to break the feature: a pick cut off while the sampler shows,
/// malformed and hostile typed text, values out of range, the gamut's edges, a store under attack,
/// two writers at once, and every action on every kind of row.
@Suite("Second pass", .timeLimit(.minutes(1)))
struct SecondPassTests {
    // MARK: Pick Color

    /// Turning the feature off cancels its handlers, but the system's sampler stays on screen until
    /// the user clicks. That click must copy nothing and write nothing.
    @Test func aPickCancelledWhileTheSamplerShowsChangesNothing() async throws {
        let sampler = HoldingSampler()
        let fakes = FakeServices()
        fakes.override(ColorSamplerKey.self, with: sampler)
        let harness = FeatureHarness(ColorsFeature.self, fakes: fakes)
        await harness.activate()
        await harness.feature.waitUntilReady()
        let started = sampler.started
        let run = Task { try await harness.run("pick") }
        for await _ in started { break }
        await harness.deactivate()
        run.cancel()
        sampler.release()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(sampler.shown == 1)
        #expect(harness.fakes.pasteboard.copied.isEmpty, "the click after the cancel copied nothing")
        #expect(harness.huds.isEmpty)
        #expect(harness.feature.history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.historyFile.path), "nothing was written")
    }

    // MARK: Typed text

    /// Text that starts like a color but is not one gets no row, and nothing crashes.
    @Test(arguments: [
        "#", "# ", "#f", "#ff", "#fffff", "#fffffff", "#fffffffff", "#ggg", "#12 34 56", "#\u{0}00", "#fff\u{202E}",
        "#６６３３９９", "#fff;", "##fff", "rgb(", "rgb()", "rgb(1 2 3", "rgb(1 2 3))", "rgb((1 2 3))", "rgb(1,2 3)",
        "rgb(1 2,3)", "rgb(1,2,3,)", "rgb(,1,2,3)", "rgb(1 2 3 4)", "rgb(1 2 / 3)", "rgb(1, 2, 3 / 0.5)",
        "rgb(1 2 3 / )", "rgb(1 2 3 // 1)", "rgb(1e309 0 0)", "rgb(-1e309 0 0)", "rgb(NaN 0 0)", "rgb(infinity 0 0)",
        "rgb(0x10 0 0)", "rgb(1e 2 3)", "rgb(+-1 2 3)", "rgb(1. 2 3)", "rgb(. 2 3)", "rgb(1px 2 3)",
        "rgb(1deg 2 3)", "rgb(1\u{0}2 3)", "rgb(1\u{202E} 2 3)", "rgb(1\n2 3)", "rgb(1 2 3)x", "rgbx(1 2 3)",
        "hsl(10% 50% 50%)", "hsl(1turnx 50% 50%)", "hwb(0 none)", "oklch(0.5 0.1 10%)", "oklch(50% 0.1)",
        "color", "color ", "color  ", "color red green", "color réd", "color \u{200B}red", "color red\u{0}",
        "color lightgoldenrodyellowx", "color re", "color 123", "contrast", "contrast ", "contrast #fff",
        "contrast #fff #000 #111", "contrast (", "contrast )", "contrast rgb(1 2 3", "contrast on on",
        "contrast #fff on", "Color History", "color history", "contrast ratio",
    ])
    func malformedTextGetsNoRow(query: String) async throws {
        let harness = await readyHarness()
        #expect(harness.instantAnswers(for: query).isEmpty, "\(query.debugDescription)")
    }

    /// Values past their range are clamped as CSS clamps them, and the row stays on one line.
    @Test func valuesOutOfRangeAreClamped() async throws {
        let cases: [(String, String)] = [
            ("rgb(300 -20 1e2)", "#FF0064"),
            ("rgb(200% 50% -5%)", "#FF8000"),
            ("rgb(1e308 1e308 1e308)", "#FFFFFF"),
            ("rgba(0 0 0 / 2)", "#000000"),
            ("rgb(0 0 0 / -1)", "#00000000"),
            ("rgb(0 0 0 / 150%)", "#000000"),
            ("hsl(120 200% -10%)", "#000000"),
            ("hsl(1e308rad 50% 50%)", "#BF4040"),
            ("hsl(-1e308turn 50% 50%)", "#BF4040"),
            ("hsl(720 100% 50%)", "#FF0000"),
            ("hsl(-120 100% 50%)", "#0000FF"),
            ("hwb(0 60% 60%)", "#808080"),
            ("hwb(0 0% 200%)", "#000000"),
            ("oklch(150% 0 0)", "#FFFFFF"),
            ("oklch(-1 0 0)", "#000000"),
        ]
        let harness = await readyHarness()
        for (query, hex) in cases {
            let row = try #require(harness.answerRow(query), "\(query)")
            #expect(row.title == hex, "\(query)")
            #expect(!row.title.contains("\n") && !(row.subtitle ?? "").contains("\n"))
        }
    }

    /// A chroma far past what any screen shows is held at the parser's limit, gives finite numbers,
    /// and says it lies outside sRGB.
    @Test func theGamutsEdgesStayFiniteAndSaySo() throws {
        for hue in stride(from: 0.0, to: 360, by: 15) {
            for lightness in [0.0, 0.05, 0.5, 0.95, 1.0] {
                let text = "oklch(\(lightness) 1e9 \(hue))"
                let color = try #require(ColorParser.parse(text, allowsNames: false), "\(text)")
                #expect(color.isFinite)
                #expect(ColorValue.componentRange.contains(color.red))
                #expect(ColorValue.componentRange.contains(color.green))
                #expect(ColorValue.componentRange.contains(color.blue))
                for format in ColorFormat.allCases {
                    let written = ColorFormatter().string(color, as: format)
                    #expect(!written.contains("nan") && !written.contains("inf"), "\(text) as \(format)")
                }
            }
        }
        let vivid = try #require(ColorParser.parse("oklch(0.7 0.4 150)", allowsNames: false))
        #expect(vivid.isOutsideSRGB)
        // Display P3's white is sRGB's white, and the corners of P3 stay finite.
        let white = ColorSpaces.fromDisplayP3(red: 1, green: 1, blue: 1)
        #expect(!white.isOutsideSRGB)
        #expect(ColorFormatter().hex(white) == "#FFFFFF")
        for corner in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0), (0.0, 0.0, 0.0)] {
            let color = ColorSpaces.fromDisplayP3(red: corner.0, green: corner.1, blue: corner.2)
            #expect(color.isFinite)
        }
    }

    /// The contrast of a color with itself is 1, black on white is 21, and a transparent text color
    /// vanishes into its background.
    @Test func contrastAtItsBounds() throws {
        #expect(Contrast(foreground: .white, background: .white).text == "1:1")
        #expect(Contrast(foreground: .black, background: .white).text == "21:1")
        #expect(Contrast(foreground: .white, background: .black).text == "21:1")
        let clear = ColorValue(red: 0, green: 0, blue: 0, alpha: 0)
        #expect(Contrast(foreground: clear, background: .white).text == "1:1")
        // Colors outside sRGB count as their nearest sRGB color.
        let vivid = ColorValue(red: 2, green: -1, blue: -1)
        let red = ColorValue(red: 1, green: 0, blue: 0)
        #expect(Contrast(foreground: vivid, background: .white) == Contrast(foreground: red, background: .white))
    }

    /// Ordinary queries are refused from their first bytes, so the provider's cost on them is a
    /// byte or a word compare.
    @Test(arguments: [
        "calendar", "chrome", "code", "contacts", "control center", "color", "colorsync utility", "contras",
        "hello", "home", "help", "rgb", "rgbx", "hsl", "oklab(0.5 0 0)", "oklc", "rainbow", "o", "r", "h", "c",
    ])
    func ordinaryQueriesAreRefusedFromTheirFirstBytes(query: String) {
        let bytes = CountingBytes(query)
        #expect(ColorQuery.kind(of: bytes) == nil)
        #expect(bytes.reads.furthest < ColorQuery.longestOpening)
    }

    // MARK: The store

    /// The history file turned into a folder, as another program might leave it, is set aside like
    /// a damaged file, and a new history starts.
    @Test func aHistoryFileThatIsAFolderIsSetAside() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.dataDirectory(for: "colors")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "history.json"), withIntermediateDirectories: true)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.isEmpty)
        await harness.feature.history.add(try color("#663399"), source: .picked)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: harness.historyFile.path, isDirectory: &isFolder))
        #expect(!isFolder.boolValue)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "history-damaged-1.json").path))
    }

    /// A history file with bytes that are not UTF-8, as a broken disk or another program may leave
    /// it, is set aside whole, kept byte for byte, and a new history starts.
    @Test func aHistoryFileWithInvalidUTF8IsSetAsideAsItWas() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.dataDirectory(for: "colors")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var bytes = Data(#"{ "version" : 1, "entries" : [ { "name" : ""#.utf8)
        bytes += Data([0xC3, 0x28, 0xFF, 0xFE])
        bytes += Data(#"" } ] }"#.utf8)
        try bytes.write(to: folder.appending(path: "history.json"))
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.isEmpty)
        #expect(!harness.feature.history.isReadOnly)
        #expect(try Data(contentsOf: folder.appending(path: "history-damaged-1.json")) == bytes)
        await harness.feature.history.add(try color("#663399"), source: .picked)
        #expect(harness.historyHexes == ["#663399"])
    }

    /// A newer version may store entries in a shape this one cannot read. Its file is neither set
    /// aside nor saved over, and settings says the history is read only.
    @Test func aNewerFileThisVersionCannotReadIsLeftWhereItIs() async throws {
        let fakes = FakeServices()
        let text =
            ##"{ "version" : 2, "entries" : { "palettes" : [ { "name" : "Sea", "colors" : [ "#0077BE" ] } ] } }"##
        try writeHistory(text, in: fakes)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.isReadOnly)
        #expect(harness.feature.status?.title == "Color History Is Read Only")
        #expect(harness.feature.history.entries.isEmpty)

        await harness.feature.history.add(try color("#663399"), source: .picked)
        #expect(harness.historyHexes == ["#663399"], "the new color shows for this session")
        #expect(try String(contentsOf: harness.historyFile, encoding: .utf8) == text, "the file was not saved over")
        let folder = fakes.storage.dataDirectory(for: "colors")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "history-damaged-1.json").path))
    }

    /// A file that is missing while the feature runs, as after the user deleted it, is written again
    /// at the next change.
    @Test func aFileDeletedWhileTheFeatureRunsIsWrittenAgain() async throws {
        let harness = await readyHarness()
        await harness.feature.history.add(try color("#663399"), source: .picked)
        try FileManager.default.removeItem(at: harness.historyFile)
        await harness.feature.history.add(try color("#66CC99"), source: .picked)
        let text = try String(contentsOf: harness.historyFile, encoding: .utf8)
        #expect(text.contains("\"version\" : 1"))
        #expect(harness.historyHexes == ["#66CC99", "#663399"])
    }

    /// Fifty colors kept at once, as from fast copies, are all kept, and the file holds them all.
    @Test func manyAddsAtOnceKeepEveryColor() async throws {
        let harness = await readyHarness()
        let history = harness.feature.history
        let adds = (0..<50).map { index in
            Task { await history.add(ColorValue(bytes: index, 0, 0), source: .typed) }
        }
        for add in adds { _ = await add.value }
        #expect(Set(history.entries.map(\.id)).count == 50)
        await harness.deactivate()
        let reopened = FeatureHarness(ColorsFeature.self, fakes: harness.fakes)
        await reopened.activate()
        await reopened.feature.waitUntilReady()
        #expect(reopened.feature.history.entries.count == 50)
    }

    // MARK: Every action on every kind of row

    /// Every action of a typed color, a contrast answer and a history row runs, and the validator
    /// finds nothing in any of the lists.
    @Test func everyActionOnEveryKindOfRowRuns() async throws {
        let harness = await readyHarness()
        harness.grantsMissingPermissions = true
        let typed = try #require(harness.answerRow("#663399"))
        for action in harness.rootActions(for: typed) {
            try await harness.perform(action, row: typed, query: "#663399", launch: .root)
        }
        let contrast = try #require(harness.answerRow("contrast #767676 on white"))
        let contrastActions = harness.rootActions(for: contrast)
        #expect(contrastActions.map(\.id) == ["copy-ratio", "copy-result"])
        for action in contrastActions {
            try await harness.perform(action, row: contrast, query: "contrast #767676 on white", launch: .root)
        }
        #expect(
            harness.fakes.pasteboard.copiedTexts.suffix(2) == [
                "4.54:1", "4.54:1, AA for normal text, AAA for large text",
            ])

        try await harness.run("history")
        let row = try #require(harness.selectedRow)
        for action in harness.actions() where !["rename", "delete", "clear-history"].contains(action.id) {
            try await harness.perform(action, row: row)
        }
        try await harness.perform("rename")
        try harness.fill("name", text: "Brand Purple")
        try await harness.submit()
        try harness.select(title: "Brand Purple")
        try await harness.perform("delete")
        #expect(harness.feature.history.entries.isEmpty)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    /// Paste needs Accessibility. With it taken away, the host's card stops the paste, and the
    /// typed color is not kept, since nothing used it.
    @Test func aPasteWithoutAccessibilityKeepsNothing() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.accessibility, to: .denied)
        let harness = await readyHarness(fakes: fakes)
        let row = try #require(harness.answerRow("#663399"))
        let paste = try #require(harness.rootActions(for: row).first { $0.title == "Paste as Hex" })
        await #expect(throws: HarnessError.self) {
            try await harness.perform(paste, row: row, query: "#663399", launch: .root)
        }
        #expect(harness.fakes.pasteboard.pasted.isEmpty)
        #expect(harness.feature.history.entries.isEmpty)
    }

    /// A typed color with control characters or a direction override never reaches a title, and
    /// a name with them is shown on one line in the order it is stored, in the row, the question
    /// and the CSS variable.
    @Test func hostileNamesStayOnOneLineEverywhere() async throws {
        let harness = await readyHarness()
        let entry = try #require(await harness.feature.history.add(try color("#663399"), source: .picked))
        await harness.feature.history.rename(entry.id, to: "Brand\u{202E}eulb\nNew\u{0}Line")
        try await harness.run("history")
        let title = try #require(harness.rows.first?.title)
        #expect(!title.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\n" || $0 == "\u{0}" })
        let delete = try #require(harness.actions().first { $0.id == "delete" })
        let question = try #require(delete.confirmation?.title)
        #expect(!question.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\n" })
        let variable = ColorFormatter().string(
            entry.color, as: .cssVariable, name: harness.feature.history.entries[0].name)
        #expect(variable.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 })
    }
}
