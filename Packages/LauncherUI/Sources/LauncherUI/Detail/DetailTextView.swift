import AppKit

/// The detail pane's text body: selectable, scrolling on its own, and cheap to append to.
///
/// It is a TextKit 1 `NSTextView` with non-contiguous layout, so only what is on screen is laid
/// out. Markdown is kept as a `MarkdownDocument`; an append replaces only the text of the last
/// block, and when that block merely grew, only the new characters are inserted.
final class DetailTextView: NSView, NSTextViewDelegate {
    /// A link in the text was clicked.
    var onOpenLink: ((URL) -> Void)?

    let scrollView = NSScrollView()
    let textView = NSTextView(usingTextLayoutManager: false)
    private var styler: MarkdownStyler?
    private var richStyler: RichStyler?
    private var kind: Kind = .plain(monospaced: false)
    private var document = MarkdownDocument()
    /// For Markdown, where each block's text sits in the storage, separators included.
    private var blockRanges: [NSRange] = []
    /// The ANSI style and any cut escape sequence at the end of the plain text shown.
    private var ansi = ANSIParser()
    private var rich = RichText(runs: [])

    private enum Kind: Equatable {
        case plain(monospaced: Bool)
        case markdown
        case rich
    }

    /// Characters laid out again by the last change, for tests: the length of what was replaced
    /// or inserted.
    private(set) var lastEditLength = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = self
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.frame.size.width = scrollView.contentSize.width
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    func apply(_ theme: ResolvedTheme) {
        let detail = theme.theme.detail
        styler = MarkdownStyler(
            style: theme.detail, metrics: detail, hairline: NSColor(cgColor: theme.hairline) ?? .separatorColor)
        richStyler = RichStyler(theme: theme)
        textView.insertionPointColor = NSColor(cgColor: theme.accent) ?? .controlAccentColor
        let padding = CGFloat(detail.padding)
        textView.textContainerInset = NSSize(width: padding - 5, height: padding)
        textView.linkTextAttributes = [
            .foregroundColor: theme.detail.text, .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: theme.detail.link, .cursor: NSCursor.pointingHand,
        ]
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        rebuild()
    }

    /// Shows a whole text body.
    func show(text: String, markdown: Bool, monospaced: Bool, lineBreaks: MarkdownLineBreaks = .standard) {
        kind = markdown ? .markdown : .plain(monospaced: monospaced)
        document = MarkdownDocument(markdown ? text : "", lineBreaks: lineBreaks)
        if !markdown { plainText = text }
        rebuild()
        textView.scroll(.zero)
    }

    /// Shows styled text.
    func show(rich text: RichText) {
        kind = .rich
        rich = text
        document = MarkdownDocument()
        plainText = ""
        rebuild()
        textView.scroll(.zero)
    }

    /// Appends to the body shown now. Keeps the view pinned to the end when it was there.
    func append(_ text: String) {
        guard !text.isEmpty, let styler, var richStyler, let storage = textView.textStorage else { return }
        let followsEnd = isScrolledToEnd
        storage.beginEditing()
        switch kind {
        case .plain(let monospaced):
            plainText += text
            let addition = richStyler.terminal(text, monospaced: monospaced, parser: &ansi)
            self.richStyler = richStyler
            storage.append(addition)
            lastEditLength = addition.length
        case .markdown:
            let first = document.append(text)
            replaceBlocks(from: first, in: storage, styler: styler)
        case .rich:
            break
        }
        storage.endEditing()
        if followsEnd { textView.scrollToEndOfDocument(nil) }
    }

    /// The text shown now, for accessibility and tests.
    var string: String { textView.string }

    private var plainText = ""

    private var isScrolledToEnd: Bool {
        let visible = scrollView.documentVisibleRect
        return visible.maxY >= textView.frame.maxY - 4
    }

    private func rebuild() {
        guard let styler, var richStyler, let storage = textView.textStorage else { return }
        storage.beginEditing()
        switch kind {
        case .plain(let monospaced):
            ansi = ANSIParser()
            storage.setAttributedString(richStyler.terminal(plainText, monospaced: monospaced, parser: &ansi))
            self.richStyler = richStyler
            blockRanges = []
        case .markdown:
            storage.setAttributedString(NSAttributedString())
            blockRanges = []
            replaceBlocks(from: 0, in: storage, styler: styler)
        case .rich:
            storage.setAttributedString(richStyler.render(rich))
            blockRanges = []
        }
        storage.endEditing()
        lastEditLength = storage.length
    }

    /// Replaces the text of blocks `first...` with a fresh rendering. When the old last block's
    /// text and attributes are a prefix of its new rendering, only the rest is inserted.
    private func replaceBlocks(from first: Int, in storage: NSTextStorage, styler: MarkdownStyler) {
        let blocks = document.blocks
        var rendered: [NSAttributedString] = []
        rendered.reserveCapacity(blocks.count - first)
        for index in first..<blocks.count {
            let text = styler.render(blocks[index])
            rendered.append(index == blocks.count - 1 ? text : Self.terminated(text))
        }
        let start = first < blockRanges.count ? blockRanges[first].location : storage.length
        let old = NSRange(location: start, length: storage.length - start)
        var insertion = NSMutableAttributedString()
        rendered.forEach(insertion.append)

        var keep = 0
        if old.length > 0, old.length <= insertion.length,
            storage.attributedSubstring(from: old).isEqual(
                to: insertion.attributedSubstring(from: NSRange(location: 0, length: old.length)))
        {
            keep = old.length
            insertion = NSMutableAttributedString(
                attributedString: insertion.attributedSubstring(
                    from: NSRange(location: keep, length: insertion.length - keep)))
        }
        storage.replaceCharacters(in: NSRange(location: start + keep, length: old.length - keep), with: insertion)
        lastEditLength = insertion.length

        blockRanges.removeSubrange(min(first, blockRanges.count)...)
        var location = start
        for text in rendered {
            blockRanges.append(NSRange(location: location, length: text.length))
            location += text.length
        }
    }

    /// `text` with a newline after it that carries its last character's attributes, so the
    /// paragraph keeps its style.
    private static func terminated(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let attributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        return result
    }

    /// The targets of the links in the text, in order, each once per run.
    var linkTargets: [URL] {
        guard let storage = textView.textStorage else { return [] }
        var targets: [URL] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let url { targets.append(url) }
        }
        return targets
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url { onOpenLink?(url) }
        // Handled: LauncherUI never opens anything itself.
        return true
    }
}
