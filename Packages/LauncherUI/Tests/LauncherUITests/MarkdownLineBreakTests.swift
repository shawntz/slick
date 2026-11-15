import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// Hard line breaks: two trailing spaces or a backslash before a newline, and the mode where every
/// newline breaks, for plain text shown as Markdown.
@Suite(.timeLimit(.minutes(1)))
struct MarkdownLineBreakTests {
    let hard = String(MarkdownParser.hardBreak)

    func blocks(_ text: String, _ lineBreaks: MarkdownLineBreaks = .standard) -> [MarkdownBlock] {
        MarkdownParser.blocks(text[...], lineBreaks: lineBreaks).map(\.block)
    }

    func paragraph(_ text: String) -> MarkdownBlock { .paragraph([MarkdownRun(text: text)]) }

    @Test func twoTrailingSpacesOrABackslashBreakTheLine() {
        #expect(blocks("Dear team,  \nSee you soon") == [paragraph("Dear team,\(hard)See you soon")])
        #expect(blocks("Dear team,     \nSee you soon") == [paragraph("Dear team,\(hard)See you soon")])
        #expect(blocks("Dear team,\\\nSee you soon") == [paragraph("Dear team,\(hard)See you soon")])
    }

    @Test func otherNewlinesStaySoft() {
        // One space, an escaped backslash, and a backslash followed by a space are not breaks.
        #expect(blocks("one \ntwo") == [paragraph("one two")])
        #expect(blocks("one\\\\\ntwo") == [paragraph("one\\ two")])
        #expect(blocks("one\\ \ntwo") == [paragraph("one\\ two")])
        #expect(blocks("one\ntwo") == [paragraph("one two")])
    }

    @Test func theLastLineNeverBreaks() {
        #expect(blocks("one  ") == [paragraph("one")])
        #expect(blocks("one\\") == [paragraph("one\\")])
        #expect(blocks("one  \n\ntwo") == [paragraph("one"), paragraph("two")])
    }

    @Test func listItemsAndQuotesBreakToo() {
        #expect(
            blocks("- first  \n  second\n> asked\\\n> answered") == [
                .listItem(marker: "•", depth: 0, [MarkdownRun(text: "first\(hard)second")]),
                .quote([MarkdownRun(text: "asked\(hard)answered")]),
            ])
    }

    @Test func aBreakInsideACodeSpanIsASpace() {
        #expect(
            blocks("`one  \ntwo`") == [.paragraph([MarkdownRun(text: "one two", style: .code)])])
    }

    @Test func emphasisSpansABreak() {
        #expect(
            blocks("**bold  \nstill bold**") == [.paragraph([MarkdownRun(text: "bold\(hard)still bold", style: .bold)])]
        )
    }

    @Test func everyNewlineBreaksInThePlainTextMode() {
        let text = "Hi {name},\nThanks for the photos.\n\nCheers\n- Sam"
        #expect(
            blocks(text, .everyNewline) == [
                paragraph("Hi {name},\(hard)Thanks for the photos."),
                paragraph("Cheers"),
                .listItem(marker: "•", depth: 0, [MarkdownRun(text: "Sam")]),
            ])
        #expect(blocks("one\ntwo\nthree", .everyNewline) == [paragraph("one\(hard)two\(hard)three")])
        // Blocks still end where Markdown ends them.
        #expect(
            blocks("one\n# Two", .everyNewline) == [paragraph("one"), .heading(level: 1, [MarkdownRun(text: "Two")])])
    }

    /// Streaming must give the same blocks as parsing the whole text at once, whatever the chunks.
    @Test(arguments: [1, 2, 3, 7])
    func appendingInChunksMatchesParsingAtOnce(chunk: Int) {
        let text = "Line one  \nline two\\\nline three\nline four\n\n> quote  \n> more\n\n- item\\\n  rest"
        for mode in [MarkdownLineBreaks.standard, .everyNewline] {
            var document = MarkdownDocument(lineBreaks: mode)
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
                document.append(String(text[index..<end]))
                index = end
            }
            #expect(document.blocks == MarkdownDocument(text, lineBreaks: mode).blocks)
        }
    }

    // MARK: In the pane

    @Test func aBrokenLineStaysInItsParagraphInThePane() throws {
        let (pane, window) = DetailPaneTests().makePane()
        defer { window.close() }
        pane.apply(DetailContent(body: .markdown("Short line  \nNext line\n\nNew paragraph")))
        #expect(pane.bodyText == "Short line\(hard)Next line\nNew paragraph")
        let lines = try Self.lineFragments(in: pane, paragraph: "Short line\(hard)Next line")
        #expect(lines == 2, "the break starts a new line inside the same paragraph")
    }

    @Test func thePaneRendersAgainWhenOnlyTheLineBreaksChange() {
        let (pane, window) = DetailPaneTests().makePane()
        defer { window.close() }
        let text = "Hi there,\nSee you at noon."
        pane.apply(DetailContent(body: .markdown(text)))
        #expect(pane.bodyText == "Hi there, See you at noon.")
        pane.apply(DetailContent(body: .markdown(text), markdownLineBreaks: .everyNewline))
        #expect(pane.bodyText == "Hi there,\(hard)See you at noon.")
        // A stream keeps the mode.
        pane.append("\nBring a coat.")
        #expect(pane.bodyText == "Hi there,\(hard)See you at noon.\(hard)Bring a coat.")
        #expect(pane.content.markdownLineBreaks == .everyNewline)
    }

    /// The line fragments the text view lays out for the paragraph that holds `text`.
    static func lineFragments(in pane: DetailPane, paragraph text: String) throws -> Int {
        let textView = pane.textView.textView
        let layout = try #require(textView.layoutManager)
        let range = (textView.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in count += 1 }
        return count
    }
}
