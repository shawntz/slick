import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct MarkdownParserTests {
    func blocks(_ text: String) -> [MarkdownBlock] { MarkdownParser.blocks(text[...]).map(\.block) }

    @Test func blockKinds() {
        let parsed = blocks(
            """
            # Title ##
            Some text
            that continues.

            - one
            2. two
            > quoted
            ---
            ```swift
            let x = 1

            print(x)
            ```
            """)
        #expect(
            parsed == [
                .heading(level: 1, [MarkdownRun(text: "Title")]),
                .paragraph([MarkdownRun(text: "Some text that continues.")]),
                .listItem(marker: "•", depth: 0, [MarkdownRun(text: "one")]),
                .listItem(marker: "2.", depth: 0, [MarkdownRun(text: "two")]),
                .quote([MarkdownRun(text: "quoted")]),
                .rule,
                .code("let x = 1\n\nprint(x)"),
            ])
    }

    @Test func inlineStyles() {
        let runs = MarkdownParser.inlines("a **bold** *it* `co*de` [link](https://example.com) snake_case_name")
        #expect(
            runs == [
                MarkdownRun(text: "a "), MarkdownRun(text: "bold", style: .bold), MarkdownRun(text: " "),
                MarkdownRun(text: "it", style: .italic), MarkdownRun(text: " "),
                MarkdownRun(text: "co*de", style: .code),
                MarkdownRun(text: " "), MarkdownRun(text: "link", link: "https://example.com"),
                MarkdownRun(text: " snake_case_name"),
            ])
    }

    @Test func unclosedDelimitersStayLiteral() {
        #expect(MarkdownParser.inlines("2 * 3 and **open") == [MarkdownRun(text: "2 * 3 and **open")])
        #expect(MarkdownParser.inlines("`tick") == [MarkdownRun(text: "`tick")])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(blocks("```\nline one\nline two") == [.code("line one\nline two")])
    }

    /// Streaming must give the same blocks as parsing the whole text at once, whatever the chunks.
    @Test(arguments: [1, 3, 7, 40])
    func appendingInChunksMatchesParsingAtOnce(chunk: Int) {
        let text = SyntheticComponents.markdown + "\n\nA closing **paragraph** with `code`.\n```\nunfinished"
        var document = MarkdownDocument()
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
            let changed = document.append(String(text[index..<end]))
            #expect(changed >= max(0, document.blocks.count - 2) || changed == 0)
            index = end
        }
        #expect(document.blocks == MarkdownDocument(text).blocks)
    }

    @Test func anAppendReparsesOnlyTheLastBlock() {
        var document = MarkdownDocument("# One\n\nTwo\n\nThree")
        #expect(document.blocks.count == 3)
        #expect(document.append(" more") == 2)
        #expect(document.append("\n\nFour") == 2)
        #expect(document.blocks.count == 4)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DetailPaneTests {
    func makePane() -> (pane: DetailPane, window: NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: 440, height: 500)
        let window = NSWindow(
            contentRect: CGRect(origin: TestSupport.offscreen.origin, size: frame.size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = DetailPane(frame: frame)
        window.contentView = pane
        pane.apply(TestSupport.lightTheme)
        window.orderFrontRegardless()
        return (pane, window)
    }

    @Test func markdownRendersHeadingsListsAndCode() {
        let (pane, window) = makePane()
        defer { window.close() }
        pane.apply(DetailContent(body: .markdown(SyntheticComponents.markdown)))
        let text = pane.bodyText
        #expect(text.hasPrefix("Release checklist\n"))
        #expect(text.contains("1.\tFreeze the branch"))
        #expect(text.contains("•\tKeep the changelog short."))
        #expect(text.contains("make release VERSION=2.4.0"))
        #expect(!text.contains("**"))
        #expect(!text.contains("```"))
    }

    @Test func streamedMarkdownMatchesTheWholeTextAndInsertsOnlyTheNewText() {
        let (pane, window) = makePane()
        defer { window.close() }
        let whole = SyntheticComponents.markdown + " Then a long closing line follows."
        pane.apply(DetailContent(body: .markdown("")))
        var index = whole.startIndex
        var lastLengths: [Int] = []
        while index < whole.endIndex {
            let end = whole.index(index, offsetBy: 5, limitedBy: whole.endIndex) ?? whole.endIndex
            pane.append(String(whole[index..<end]))
            lastLengths.append(pane.textView.lastEditLength)
            index = end
        }
        let (reference, referenceWindow) = makePane()
        defer { referenceWindow.close() }
        reference.apply(DetailContent(body: .markdown(whole)))
        #expect(pane.bodyText == reference.bodyText)
        // The last chunks extend one paragraph, so each inserts only its own characters.
        #expect(lastLengths.suffix(4).allSatisfy { $0 <= 5 })
    }

    @Test func applyingAGrowingAnswerAppends() {
        let (pane, window) = makePane()
        defer { window.close() }
        pane.apply(DetailContent(body: .text("Hello")))
        pane.apply(DetailContent(body: .text("Hello, world")))
        #expect(pane.bodyText == "Hello, world")
        #expect(pane.textView.lastEditLength == 7)
    }

    @Test func linksAreReportedNotOpened() throws {
        let (pane, window) = makePane()
        defer { window.close() }
        var opened: [URL] = []
        pane.onOpenLink = { opened.append($0) }
        pane.apply(DetailContent(body: .markdown("[notes](https://example.com/notes)")))
        let handled = pane.textView.textView(
            pane.textView.textView, clickedOnLink: try #require(URL(string: "https://example.com/notes")), at: 0)
        #expect(handled)
        #expect(opened == [URL(string: "https://example.com/notes")])
    }

    @Test func metadataSitsUnderTheBody() {
        let (pane, window) = makePane()
        defer { window.close() }
        pane.apply(DetailContent(body: .text("Body"), metadata: SyntheticComponents.metadata))
        pane.layoutSubtreeIfNeeded()
        let table = pane.metadataView.contentHeight()
        #expect(table > 0)
        #expect(pane.textView.frame.maxY <= pane.bounds.height - table)
    }

    @Test func theSplitGivesTheListItsShare() {
        let split = ListDetailView(frame: CGRect(x: 0, y: 0, width: 760, height: 500))
        split.apply(TestSupport.lightTheme)
        split.layoutSubtreeIfNeeded()
        #expect(Double(split.list.frame.width) == (760 * Theme.standard.detail.listFraction).rounded())
        #expect(split.preferredContentHeight(limit: 500) == 0)
        split.list.apply(SyntheticComponents.historyRows())
        #expect(split.preferredContentHeight(limit: 500) == 500)
    }
}
