import AppKit

/// The detail pane: a body on top (text, Markdown, an image, a colour or a file) and a metadata
/// table pinned under it, split by a hairline. The body scrolls on its own, and its text can be
/// selected and copied.
///
/// Beside a list it lives in `ListDetailView`; on its own it fills the content area as a detail
/// page. Text bodies accept appended text cheaply, for answers that stream in.
public final class DetailPane: NSView, LauncherContentView {
    /// A link in the body or the metadata was clicked. LauncherUI never opens links itself.
    public var onOpenLink: ((URL) -> Void)? {
        didSet {
            textView.onOpenLink = onOpenLink
            metadataView.onOpenLink = onOpenLink
        }
    }
    public var contentHeightDidChange: (() -> Void)?
    /// Unused: the pane shows no selection.
    public weak var selectionLens: SelectionLens?

    public private(set) var content: DetailContent = .empty

    let textView = DetailTextView()
    let visualView = DetailVisualView()
    private let metadataScroll = NSScrollView()
    let metadataView = MetadataView()
    private let divider = NSView()
    private(set) var theme: ResolvedTheme?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        metadataScroll.drawsBackground = false
        metadataScroll.hasVerticalScroller = true
        metadataScroll.scrollerStyle = .overlay
        metadataScroll.autohidesScrollers = true
        metadataScroll.borderType = .noBorder
        metadataScroll.documentView = metadataView
        divider.wantsLayer = true
        for view in [textView, visualView, metadataScroll, divider] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public func preferredContentHeight(limit: CGFloat) -> CGFloat { content.isEmpty ? 0 : limit }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        textView.apply(theme)
        visualView.apply(theme)
        metadataView.apply(theme)
        divider.layer?.backgroundColor = theme.hairline
        needsLayout = true
    }

    /// Shows new content. When the new body is the same kind of text and starts with the old
    /// text, only the new end is appended, so a host that re-sends a growing answer pays for the
    /// growth, not the whole answer.
    public func apply(_ newContent: DetailContent) {
        guard newContent != content else { return }
        let old = content
        content = newContent
        if let body = newContent.body, let text = body.text {
            if let oldBody = old.body, oldBody.isSameTextKind(as: body), let oldText = oldBody.text,
                text.utf8.count > oldText.utf8.count, text.hasPrefix(oldText)
            {
                textView.append(String(text.utf8.dropFirst(oldText.utf8.count)) ?? "")
            } else if old.body != body {
                switch body {
                case .markdown: textView.show(text: text, markdown: true, monospaced: false)
                case .monospaced: textView.show(text: text, markdown: false, monospaced: true)
                case .richText(let rich): textView.show(rich: rich)
                default: textView.show(text: text, markdown: false, monospaced: false)
                }
            }
        }
        switch newContent.body {
        case .image(let image): visualView.visual = .image(image)
        case .color(let color, let caption): visualView.visual = .color(color, caption: caption)
        case .file(let name, let thumbnail): visualView.visual = .file(name: name, thumbnail: thumbnail)
        default: break
        }
        metadataView.items = newContent.metadata
        setAccessibilityLabel(newContent.body?.text == nil ? nil : String(textView.string.prefix(200)))
        needsLayout = true
        if old.isEmpty != newContent.isEmpty { contentHeightDidChange?() }
    }

    /// Appends text to a text or Markdown body, as the next chunk of a streamed answer arrives.
    public func append(_ text: String) {
        guard let body = content.body, let current = body.text, !text.isEmpty else { return }
        switch body {
        case .text: content.body = .text(current + text)
        case .monospaced: content.body = .monospaced(current + text)
        case .markdown: content.body = .markdown(current + text)
        default: return
        }
        textView.append(text)
    }

    /// Fills the image of an image body or the thumbnail of a file body once it is ready.
    public func setImage(_ image: CGImage?) {
        switch content.body {
        case .image: apply(DetailContent(body: .image(image), metadata: content.metadata))
        case .file(let name, _):
            apply(DetailContent(body: .file(name: name, thumbnail: image), metadata: content.metadata))
        default: break
        }
    }

    /// The body text shown now, for tests and accessibility.
    public var bodyText: String { textView.string }

    override public func layout() {
        super.layout()
        guard let theme else { return }
        let metrics = theme.theme.detail
        let hasBody = content.body != nil
        let isText = content.body?.text != nil
        let tableHeight = metadataView.contentHeight()
        let shownTable =
            hasBody
            ? min(tableHeight, bounds.height * CGFloat(metrics.metadataMaxFraction)) : min(tableHeight, bounds.height)
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        var bodyHeight = bounds.height - (shownTable > 0 && hasBody ? shownTable + hairline : 0)
        if !isText, let wanted = visualView.preferredHeight(width: bounds.width) {
            bodyHeight = min(bodyHeight, wanted)
        }

        textView.isHidden = !isText
        visualView.isHidden = !hasBody || isText
        textView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bodyHeight)
        visualView.frame = textView.frame
        let tableTop = hasBody ? bounds.height - shownTable : 0
        divider.isHidden = !(hasBody && shownTable > 0)
        divider.frame = CGRect(
            x: CGFloat(metrics.padding), y: tableTop - hairline, width: bounds.width - CGFloat(metrics.padding) * 2,
            height: hairline)
        metadataScroll.isHidden = shownTable == 0
        metadataScroll.frame = CGRect(x: 0, y: tableTop, width: bounds.width, height: shownTable)
        metadataView.frame = CGRect(x: 0, y: 0, width: metadataScroll.contentSize.width, height: tableHeight)
    }
}
