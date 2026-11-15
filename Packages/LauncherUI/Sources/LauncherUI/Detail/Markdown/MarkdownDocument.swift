/// A Markdown source and its blocks, kept up to date as text is appended.
///
/// An append re-parses only from the start of the last block, the one block that new text can
/// change, so streaming an answer costs the size of the last block per chunk, not the size of the
/// document.
nonisolated struct MarkdownDocument: Sendable, Equatable {
    private(set) var source = ""
    private(set) var blocks: [MarkdownBlock] = []
    /// How a newline inside a paragraph reads.
    let lineBreaks: MarkdownLineBreaks
    /// The UTF-8 offset in `source` where each block starts.
    private var starts: [Int] = []

    init(_ source: String = "", lineBreaks: MarkdownLineBreaks = .standard) {
        self.lineBreaks = lineBreaks
        replace(with: source)
    }

    /// Replaces the whole document.
    mutating func replace(with source: String) {
        self.source = source
        let parsed = MarkdownParser.blocks(source[...], lineBreaks: lineBreaks)
        blocks = parsed.map(\.block)
        starts = parsed.map(\.start)
    }

    /// Appends text. Returns the index of the first block that changed: every block from there on
    /// is new or different, and every block before it is untouched.
    @discardableResult
    mutating func append(_ text: String) -> Int {
        let first = max(0, blocks.count - 1)
        let offset = starts.isEmpty ? 0 : starts[first]
        source += text
        let tail = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
        let parsed = MarkdownParser.blocks(source[tail...], lineBreaks: lineBreaks)
        blocks.replaceSubrange(first..., with: parsed.map(\.block))
        starts.replaceSubrange(first..., with: parsed.map { $0.start + offset })
        return first
    }
}
