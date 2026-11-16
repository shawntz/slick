import AppKit

/// A result list beside a detail pane, split by a vertical hairline. The list takes the theme's
/// `listFraction` of the width and the pane the rest.
///
/// Fill `list` and `detail` directly; the split only lays them out and passes the lens to the
/// list. While the list has rows it asks for the full content height, because the pane needs room.
public final class ListDetailView: NSView, LauncherContentView {
    public let list = ResultListView()
    public let detail = DetailPane()
    public var contentHeightDidChange: (() -> Void)?
    public weak var selectionLens: SelectionLens? {
        didSet { list.selectionLens = selectionLens }
    }

    private let divider = NSView()
    private var listFraction = Theme.standard.detail.listFraction

    override public init(frame: NSRect) {
        super.init(frame: frame)
        divider.wantsLayer = true
        for view in [list, divider, detail] as [NSView] { addSubview(view) }
        // Beside a detail pane the titles need the room more than the hints do. The chords still
        // run the rows.
        list.hidesRunHints = true
        list.contentHeightDidChange = { [weak self] in self?.contentHeightDidChange?() }
        detail.contentHeightDidChange = { [weak self] in self?.contentHeightDidChange?() }
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        list.content.rowCount > 0 || !detail.content.isEmpty ? limit : 0
    }

    /// Sizes the list and the pane at once, not on the next layout pass: the list reveals its
    /// selection against its own height, so it must have one before content arrives.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOutParts()
    }

    public func apply(_ theme: ResolvedTheme) {
        listFraction = theme.theme.detail.listFraction
        divider.layer?.backgroundColor = theme.hairline
        list.apply(theme)
        detail.apply(theme)
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        layOutParts()
    }

    private func layOutParts() {
        let listWidth = (bounds.width * CGFloat(listFraction)).rounded()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        list.frame = CGRect(x: 0, y: 0, width: listWidth, height: bounds.height)
        divider.frame = CGRect(x: listWidth, y: 0, width: hairline, height: bounds.height)
        detail.frame = CGRect(
            x: listWidth + hairline, y: 0, width: bounds.width - listWidth - hairline, height: bounds.height)
    }
}
