import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite struct ANSIParserTests {
    @Test func colourCodesSplitTheTextIntoStyledRuns() {
        var parser = ANSIParser()
        let runs = parser.parse("ok \u{1B}[1;31mfailed\u{1B}[0m done")
        #expect(runs.map(\.text) == ["ok ", "failed", " done"])
        #expect(runs[1].style.isBold)
        #expect(runs[1].style.foreground == .palette(1))
        #expect(runs[2].style.isPlain)
    }

    @Test func extendedColoursAndResets() {
        var parser = ANSIParser()
        let runs = parser.parse("\u{1B}[38;5;208ma\u{1B}[38;2;10;20;30;48;5;4mb\u{1B}[39;49mc")
        #expect(runs.map(\.text) == ["a", "b", "c"])
        #expect(runs[0].style.foreground == .palette(208))
        #expect(runs[1].style.foreground == .rgb(red: 10, green: 20, blue: 30))
        #expect(runs[1].style.background == .palette(4))
        #expect(runs[2].style.isPlain)
    }

    @Test func otherSequencesAreDropped() {
        var parser = ANSIParser()
        let runs = parser.parse("a\u{1B}[2Kb\u{1B}]0;title\u{07}c\u{1B}]8;;https://example.com\u{1B}\\d\u{1B}7e")
        #expect(runs.map(\.text).joined() == "abcde")
    }

    @Test func aSequenceCutBetweenChunksIsCompletedByTheNext() {
        var parser = ANSIParser()
        let first = parser.parse("red: \u{1B}[3")
        #expect(first.map(\.text) == ["red: "])
        #expect(!parser.passesThrough("1m"))
        let second = parser.parse("1mwarm\u{1B}[")
        #expect(second.map(\.text) == ["warm"])
        #expect(second[0].style.foreground == .palette(1))
        let third = parser.parse("0mplain")
        #expect(third.map(\.text) == ["plain"])
        #expect(third[0].style.isPlain)
        #expect(parser.passesThrough("more"))
    }

    @Test func paletteEntriesBecomeColours() {
        #expect(ANSIColor.palette(1).system == .red)
        #expect(ANSIColor.palette(9).system == .red)
        #expect(ANSIColor.palette(16).srgb.map { $0.red == 0 && $0.green == 0 && $0.blue == 0 } == true)
        #expect(ANSIColor.palette(231).srgb.map { $0.red == 1 && $0.blue == 1 } == true)
        #expect(ANSIColor.palette(232).srgb.map { abs($0.red - 8 / 255) < 0.001 } == true)
    }
}

@Suite struct LegibleColorTests {
    @Test func coloursReachTheRatioOverTheReference() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        for color in [(red: 0.0, green: 0.0, blue: 0.0), (0.9, 0.1, 0.1), (0.1, 0.2, 0.9), (0.53, 0.26, 0.98)] {
            let onDark = LegibleColor.adjust(
                color, toward: white, reference: LegibleColor.darkReferenceLuminance, minimumRatio: 4.5)
            let darkRatio = LegibleColor.ratio(
                LegibleColor.luminance(red: onDark.red, green: onDark.green, blue: onDark.blue),
                LegibleColor.darkReferenceLuminance)
            #expect(darkRatio >= 4.5)
            let onLight = LegibleColor.adjust(
                color, toward: black, reference: LegibleColor.lightReferenceLuminance, minimumRatio: 4.5)
            let lightRatio = LegibleColor.ratio(
                LegibleColor.luminance(red: onLight.red, green: onLight.green, blue: onLight.blue),
                LegibleColor.lightReferenceLuminance)
            #expect(lightRatio >= 4.5)
        }
    }

    @Test func aColourThatPassesIsKeptAndHueSurvives() {
        let pale = (red: 1.0, green: 0.92, blue: 0.92)
        let kept = LegibleColor.adjust(
            pale, toward: (1, 1, 1), reference: LegibleColor.darkReferenceLuminance, minimumRatio: 4.5)
        #expect(kept.red == pale.red && kept.green == pale.green)
        let red = LegibleColor.adjust(
            (0.8, 0.1, 0.1), toward: (1, 1, 1), reference: LegibleColor.darkReferenceLuminance, minimumRatio: 4.5)
        #expect(red.red > red.green)
    }
}

@Suite struct DetailStylingTests {
    func makePane(dark: Bool = false) -> DetailPane {
        let pane = DetailPane(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let theme = ResolvedTheme(
            theme: .standard, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!,
            accessibility: DisplayAccessibility())
        pane.apply(theme)
        return pane
    }

    func color(_ pane: DetailPane, at index: Int) -> NSColor? {
        pane.textView.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @Test func terminalColoursDrawAsLegibleColour() throws {
        _ = NSApplication.shared
        let pane = makePane(dark: true)
        pane.apply(DetailContent(body: .monospaced("ok \u{1B}[30mblack\u{1B}[0m")))
        #expect(pane.bodyText == "ok black")
        // Black text on dark glass is lifted until it reaches 4.5:1.
        let black = try #require(color(pane, at: 3)?.usingColorSpace(.sRGB))
        let luminance = LegibleColor.luminance(
            red: Double(black.redComponent), green: Double(black.greenComponent), blue: Double(black.blueComponent))
        #expect(LegibleColor.ratio(luminance, LegibleColor.darkReferenceLuminance) >= 4.5)
    }

    @Test func streamedTerminalOutputKeepsItsStyleAcrossChunks() throws {
        _ = NSApplication.shared
        let pane = makePane()
        pane.apply(DetailContent(body: .monospaced("a\u{1B}[3")))
        pane.append("2mgreen\u{1B}[0m")
        #expect(pane.bodyText == "agreen")
        let plain = try #require(color(pane, at: 0))
        let green = try #require(color(pane, at: 1))
        #expect(plain != green)
    }

    @Test func richTextKeepsSizesAndColoursWithinTheRules() throws {
        _ = NSApplication.shared
        let pane = makePane()
        let rich = RichText(runs: [
            RichText.Run("Title\n", sizeScale: 4, isBold: true),
            RichText.Run("tiny ", sizeScale: 0.2),
            RichText.Run("yellow", color: ThemeColor(red: 1, green: 0.9, blue: 0)),
            RichText.Run(" link", link: "https://example.com"),
        ])
        pane.apply(DetailContent(body: .richText(rich)))
        #expect(pane.bodyText == "Title\ntiny yellow link")
        let storage = try #require(pane.textView.textView.textStorage)
        let body = TestSupport.lightTheme.detail.textFont.pointSize
        let title = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let tiny = try #require(storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(title.pointSize <= (body * CGFloat(RichText.maximumScale)).rounded())
        #expect(tiny.pointSize >= (body * CGFloat(RichText.minimumScale)).rounded())
        #expect(NSFontManager.shared.traits(of: title).contains(.boldFontMask))
        let yellow = try #require(color(pane, at: 11)?.usingColorSpace(.sRGB))
        let luminance = LegibleColor.luminance(
            red: Double(yellow.redComponent), green: Double(yellow.greenComponent),
            blue: Double(yellow.blueComponent))
        #expect(LegibleColor.ratio(luminance, LegibleColor.lightReferenceLuminance) >= 4.5)
        #expect(storage.attribute(.link, at: storage.length - 1, effectiveRange: nil) != nil)
    }

    @Test func richTextReadsAnAttributedString() {
        let source = NSMutableAttributedString(
            string: "Big", attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red])
        source.append(NSAttributedString(string: " body", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let rich = RichText(source, bodySize: 12)
        #expect(rich.plainText == "Big body")
        #expect(rich.runs.count == 2)
        #expect(rich.runs[0].isBold)
        #expect(rich.runs[0].sizeScale == 2)
        #expect(rich.runs[0].color != nil)
        #expect(rich.runs[1].color == nil)
    }

    @Test func metadataLabelsTakeAnIcon() {
        _ = NSApplication.shared
        let pane = makePane()
        pane.apply(
            DetailContent(
                body: .text("Body"),
                metadata: [.iconLabel("Application", value: "Example Editor", icon: .symbol("app"))]))
        #expect(pane.metadataView.contentHeight() > 0)
        let children = pane.metadataView.accessibilityChildren() as? [NSAccessibilityElement]
        #expect(children?.first?.accessibilityLabel() == "Application: Example Editor")
    }
}
