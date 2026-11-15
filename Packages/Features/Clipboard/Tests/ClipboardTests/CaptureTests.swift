import Foundation
import Kit
import Testing

@testable import Clipboard

@Suite("What a copy keeps", .timeLimit(.minutes(1)))
struct CaptureTests {
    private func capture(_ contents: [PasteboardContent], maximumBytes: Int = 1 << 20) -> Capture? {
        Capture(
            PasteboardEntry(
                contents: contents, sourceBundleID: "com.example.editor", date: .distantPast, changeCount: 1),
            maximumBytes: maximumBytes)
    }

    @Test func plainTextThatIsALoneLinkOrColorKeepsThatKind() {
        #expect(capture([.text("  https://example.com/a  ")])?.kind == .link)
        #expect(capture([.text("  https://example.com/a  ")])?.text == "https://example.com/a")
        #expect(capture([.text("#FF8800")])?.kind == .color)
        #expect(capture([.text("#ff880080")])?.kind == .color)
        #expect(capture([.text("#abc")])?.kind == .color)
        #expect(capture([.text("#123")])?.kind == .text, "an issue number stays text")
        #expect(capture([.text("#12345")])?.kind == .text)
        #expect(capture([.text("FF8800")])?.kind == .text, "a color needs its #")
        #expect(capture([.text("see https://example.com/a")])?.kind == .text)
        #expect(capture([.text("ftp://example.com/a")])?.kind == .text)
        #expect(capture([.text("  indented\n")])?.text == "  indented\n", "text is kept exactly")
    }

    @Test func filesWinThenRichTextThenImagesThenLinksThenText() {
        let png = Samples.png(width: 2, height: 2)
        #expect(capture([.files([Samples.fileA]), .text("x")])?.kind == .files)
        #expect(
            capture([.image(png, typeIdentifier: "public.png"), .richText(rtf: Samples.rtf, plain: "Cells")])?.kind
                == .richText)
        #expect(capture([.image(png, typeIdentifier: "public.png"), .url(Samples.link)])?.kind == .image)
        #expect(capture([.url(Samples.link), .text("label")])?.kind == .link)
        #expect(capture([.url(Samples.fileA)])?.kind == .files)
        #expect(capture([.richText(rtf: Samples.rtf, plain: Samples.link.absoluteString)])?.kind == .link)
    }

    @Test func emptyAndOversizedContentIsNotKept() {
        #expect(capture([.text("   \n\t")]) == nil)
        #expect(capture([.files([])]) == nil)
        #expect(capture([]) == nil)
        #expect(capture([.text(String(repeating: "a", count: 101))], maximumBytes: 100) == nil)
        #expect(
            capture([.image(Samples.fakeImage(bytes: 101, seed: 1), typeIdentifier: "public.png")], maximumBytes: 100)
                == nil)
        let rich = capture([.richText(rtf: Data(count: 200), plain: "short")], maximumBytes: 100)
        #expect(rich?.kind == .text && rich?.rtf == nil, "styling over the cap is dropped, the text kept")
    }

    @Test func keysAreStableAndHex() {
        let key = TemporaryStore.capture("same").key
        #expect(key == TemporaryStore.capture("same").key)
        #expect(key != TemporaryStore.capture("other").key)
        #expect(ItemKey(hex: key.hex) == key)
        #expect(key.hex.count == 16)
        #expect(ItemKey(hex: "xyz") == nil)
        #expect(TemporaryStore.capture("/tmp/a").key != capture([.files([URL(filePath: "/tmp/a")])])?.key)
    }

    @Test func searchQueriesSplitLongAndShortWords() {
        let query = SearchQuery("  ab \"cd\" efg 100% ")
        #expect(query.words == ["ab", "\"cd\"", "efg", "100%"])
        #expect(query.matchExpression == #""""cd""" AND "efg" AND "100%""#)
        #expect(query.likePatterns == ["%ab%"])
        #expect(SearchQuery("a_").likePatterns == [#"%a\_%"#])
        #expect(SearchQuery(" ").isEmpty)
    }
}
