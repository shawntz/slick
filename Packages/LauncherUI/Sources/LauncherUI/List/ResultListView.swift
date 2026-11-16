import AppKit

/// The result list: one view that draws every visible header and row with Core Text.
///
/// One view instead of a view per row is the measured fast path: about 1.5 to 2 ms of main-thread
/// time to update nine changed rows, against 4 to 5 ms for pooled label rows and 10 to 17 ms for
/// SwiftUI or `NSTableView`. Updates are diffed per line, so an unchanged row is not redrawn, and
/// typeset rows are cached, so scrolling only draws. Accessibility elements are built when a
/// client asks, so they cost nothing per keystroke.
///
/// The view's frame is the full content area; only the top `preferredContentHeight` is used,
/// and nothing is drawn below it, because the action bar sits there.
public final class ResultListView: NSView, LauncherContentView {
    /// The selected row changed by a click or an accessibility action. Selection changes made
    /// through `select(_:animated:)` are not reported.
    public var onSelect: ((Int) -> Void)?
    /// A row was double-clicked or pressed through accessibility.
    public var onActivate: ((Int) -> Void)?
    /// Scrolling changed which rows are visible: the wheel, a selection scrolled into view, or
    /// `scroll(to:)`. It gets the rows now visible, counted across sections. `apply(_:)` does not
    /// call it; read `visibleRows` after new content instead.
    public var onVisibleRowsChange: ((Range<Int>) -> Void)?
    public var contentHeightDidChange: (() -> Void)?
    public weak var selectionLens: SelectionLens? {
        didSet { updateLens(animated: false) }
    }

    public private(set) var content: ListContent = .empty
    /// The selected row, counted across sections.
    public private(set) var selectedRow: Int?
    /// How far the content is scrolled, in points.
    public private(set) var scrollOffset: CGFloat = 0

    /// Display passes so far, and rows drawn by the last one. Tests read them to check diffing.
    private(set) var displayPasses = 0
    private(set) var rowsDrawnInLastPass = 0

    private(set) var layoutModel = ListLayout(content: .empty, metrics: Theme.standard.list, maxHeight: 0)
    private(set) var theme: ResolvedTheme?
    private var typesets: [Int: RowTypeset] = [:]
    private var typesetWidth: CGFloat = 0
    /// Lines kept across updates, so rows that keep their text are not typeset again. Benchmarks
    /// turn it off to compare.
    let lineCache = RowLineCache()
    @_spi(Testing) public var usesLineCache = true
    /// Leaves out the Command-digit hints even in a theme that shows them, as a list beside a
    /// detail pane does.
    var hidesRunHints = false {
        didSet {
            guard hidesRunHints != oldValue else { return }
            typesets.removeAll(keepingCapacity: true)
            needsDisplay = true
        }
    }
    private let indicator = ScrollIndicatorView()
    var accessibilityCache: [NSAccessibilityElement]?
    /// The visible rows last reported through `onVisibleRowsChange`.
    /// Nil after new content: the next scroll reports.
    private var reportedVisibleRows: Range<Int>?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Growing or shrinking the view never stretches what is already drawn.
        layerContentsPlacement = .topLeft
        indicator.isHidden = true
        addSubview(indicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    // The query field keeps first responder; the list only takes clicks and scrolls.
    override public var acceptsFirstResponder: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        min(limit, CGFloat(layoutModel.viewportHeight))
    }

    /// The visible height: the top part of the view that shows rows.
    var viewportHeight: CGFloat { min(bounds.height, CGFloat(layoutModel.viewportHeight)) }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        typesets.removeAll(keepingCapacity: true)
        lineCache.removeAll()
        indicator.apply(theme)
        relayout(content)
        needsDisplay = true
        updateLens(animated: false)
    }

    /// Shows new content. Lines that look the same as before at the same place are not redrawn.
    /// The selection is kept when its row still exists and cleared otherwise.
    public func apply(_ newContent: ListContent) {
        guard newContent != content else { return }
        let oldContent = content
        let oldLayout = layoutModel
        let oldOffset = scrollOffset
        let oldViewport = viewportHeight
        content = newContent
        relayout(newContent)
        scrollOffset = min(scrollOffset, CGFloat(layoutModel.maxScrollOffset))
        if let row = selectedRow, row >= layoutModel.rowCount { selectedRow = nil }

        let styleChanged =
            oldContent.rowStyle != newContent.rowStyle
            || oldContent.emphasizesMatches != newContent.emphasizesMatches
            || oldContent.showsRunHints != newContent.showsRunHints
        if styleChanged || oldOffset != scrollOffset {
            typesets.removeAll(keepingCapacity: true)
            setNeedsDisplay(bounds)
        } else {
            invalidateChangedLines(old: oldContent, oldLayout: oldLayout, oldViewport: oldViewport)
        }
        if accessibilityCache != nil {
            accessibilityCache = nil
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        indicator.update(offset: scrollOffset, content: layoutModel.contentHeight, viewport: viewportHeight)
        updateLens(animated: false)
        reportedVisibleRows = nil
        if oldLayout.viewportHeight != layoutModel.viewportHeight { contentHeightDidChange?() }
    }

    /// The rows at least partly inside the visible height, counted across sections.
    public var visibleRows: Range<Int> {
        let top = Double(scrollOffset)
        return layoutModel.rowIndices(overlapping: top, top + Double(viewportHeight))
    }

    /// Fills in the icon of every row with `id`, redrawing only those rows.
    public func setIcon(_ image: CGImage?, forRow id: UInt64) {
        var index = 0
        for section in content.sections.indices {
            for row in content.sections[section].rows.indices {
                if content.sections[section].rows[row].id == id {
                    content.sections[section].rows[row].icon = image
                    if let rect = rowRect(index) { setNeedsDisplay(rect) }
                }
                index += 1
            }
        }
    }

    /// The row at `index`, counted across sections.
    public func row(at index: Int) -> ListRow? {
        Self.row(index, layoutModel, content)
    }

    /// The frame of row `index` in view coordinates, whether or not it is scrolled into view.
    public func rowRect(_ index: Int) -> CGRect? {
        guard let line = layoutModel.rowLine(index) else { return nil }
        return CGRect(x: 0, y: CGFloat(line.y) - scrollOffset, width: bounds.width, height: CGFloat(line.height))
    }

    // MARK: Selection

    /// Selects row `index`, or nothing, scrolling it into view. The lens glides when `animated`
    /// and the theme's motion allows it.
    public func select(_ index: Int?, animated: Bool) {
        guard let index, index >= 0, index < layoutModel.rowCount else {
            selectedRow = nil
            updateLens(animated: false)
            return
        }
        let changed = selectedRow != index
        selectedRow = index
        if changed, accessibilityCache != nil {
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
        scrollToReveal(index)
        updateLens(animated: animated)
    }

    /// Moves the selection by `delta` rows, stopping at either end. Returns the new selection.
    @discardableResult
    public func moveSelection(by delta: Int, animated: Bool = true) -> Int? {
        guard layoutModel.rowCount > 0 else { return nil }
        let target = min(max(0, (selectedRow ?? -1) + delta), layoutModel.rowCount - 1)
        select(target, animated: animated)
        return target
    }

    /// Moves the selection to the first row of the next or previous section. Returns the new
    /// selection, or nil when there is no section that way.
    @discardableResult
    public func moveSelectionToSection(forward: Bool, animated: Bool = true) -> Int? {
        let current = selectedRow ?? 0
        guard
            let target = forward
                ? layoutModel.nextSectionStart(after: current) : layoutModel.previousSectionStart(before: current)
        else { return nil }
        select(target, animated: animated)
        return target
    }

    // MARK: Scrolling

    /// Scrolls so the content at `offset` is at the top, clamped to the content.
    public func scroll(to offset: CGFloat) {
        let clamped = min(max(0, offset), CGFloat(layoutModel.maxScrollOffset)).rounded()
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        setNeedsDisplay(bounds)
        indicator.update(offset: scrollOffset, content: layoutModel.contentHeight, viewport: viewportHeight)
        updateLens(animated: false)
        let visible = visibleRows
        guard visible != reportedVisibleRows else { return }
        reportedVisibleRows = visible
        onVisibleRowsChange?(visible)
    }

    override public func scrollWheel(with event: NSEvent) {
        guard layoutModel.maxScrollOffset > 0, let theme else { return }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= CGFloat(theme.theme.list.wheelLineHeight) }
        scroll(to: scrollOffset - delta)
        indicator.flash()
    }

    private func scrollToReveal(_ index: Int) {
        guard let line = layoutModel.rowLine(index), let theme else { return }
        let padding = CGFloat(theme.theme.list.verticalPadding)
        var top = CGFloat(line.y)
        // Bring the section header along when revealing a section's first row.
        if let lineIndex = layoutModel.lineIndices(overlapping: line.y, line.maxY).first, lineIndex > 0,
            case .header = layoutModel.lines[lineIndex - 1].kind
        {
            top = CGFloat(layoutModel.lines[lineIndex - 1].y)
        }
        if top - padding < scrollOffset {
            scroll(to: top - padding)
        } else if CGFloat(line.maxY) + padding > scrollOffset + viewportHeight {
            scroll(to: CGFloat(line.maxY) + padding - viewportHeight)
        }
    }

    // MARK: Pointer

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < viewportHeight, let index = layoutModel.rowIndex(atY: Double(point.y + scrollOffset)) else {
            return
        }
        if event.clickCount >= 2 {
            onActivate?(index)
        } else {
            select(index, animated: true)
            onSelect?(index)
        }
    }

    // MARK: Drawing

    override public func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        let heightChanged = newSize.height != frame.height
        super.setFrameSize(newSize)
        if widthChanged { typesets.removeAll(keepingCapacity: true) }
        if heightChanged { relayout(content) }
        indicator.update(offset: scrollOffset, content: layoutModel.contentHeight, viewport: viewportHeight)
        setNeedsDisplay(bounds)
    }

    override public func draw(_ dirtyRect: NSRect) {
        displayPasses += 1
        rowsDrawnInLastPass = 0
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let viewport = viewportHeight
        context.touchCorners(of: bounds)
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: viewport))
        let scale = window?.backingScaleFactor ?? 2
        let minY = Double(max(dirtyRect.minY, 0) + scrollOffset)
        let maxY = Double(min(dirtyRect.maxY, viewport) + scrollOffset)
        for lineIndex in layoutModel.lineIndices(overlapping: minY, maxY) {
            let line = layoutModel.lines[lineIndex]
            let rect = CGRect(
                x: 0, y: CGFloat(line.y) - scrollOffset, width: bounds.width, height: CGFloat(line.height))
            guard needsToDraw(rect) else { continue }
            switch line.kind {
            case .header(let section):
                RowRenderer.drawHeader(
                    content.sections[section].headerText ?? "", top: rect.minY, in: context, theme: theme,
                    scale: scale)
            case .row(let section, let row, let index):
                let model = content.sections[section].rows[row]
                RowRenderer.drawRow(
                    typeset(index, model, height: rect.height, scale: scale), icon: model.icon,
                    at: rect.origin, in: context, theme: theme)
                rowsDrawnInLastPass += 1
            }
        }
    }

    // MARK: Internals

    private func relayout(_ content: ListContent) {
        guard let theme else { return }
        layoutModel = ListLayout(content: content, metrics: theme.theme.list, maxHeight: Double(bounds.height))
    }

    /// The Command-digit chord that runs row `index`, when the theme shows run hints.
    func runHint(forRow index: Int) -> String? {
        guard theme?.theme.list.showsRunHints == true, showsHints else { return nil }
        return RunHint.text(forRow: index)
    }

    func typeset(_ index: Int, _ row: ListRow, height: CGFloat, scale: CGFloat) -> RowTypeset {
        if typesetWidth != bounds.width {
            typesets.removeAll(keepingCapacity: true)
            typesetWidth = bounds.width
        }
        if let cached = typesets[index] { return cached }
        let typeset = RowTypesetter.typeset(
            row, index: showsHints ? index : nil, width: bounds.width, height: height, style: content.rowStyle,
            emphasizesMatches: content.emphasizesMatches, theme: theme ?? fallbackTheme, scale: scale,
            lines: usesLineCache ? lineCache : nil
        )
        typesets[index] = typeset
        return typeset
    }

    /// Whether this list's rows may show run hints: the page runs them by chord and the list is
    /// not beside a detail pane.
    private var showsHints: Bool { content.showsRunHints && !hidesRunHints }

    private var fallbackTheme: ResolvedTheme {
        ResolvedTheme(theme: .standard, appearance: effectiveAppearance, accessibility: .current)
    }

    /// Marks the lines whose look changed. A line is clean when the old content had the same
    /// header or row at the same place.
    private func invalidateChangedLines(old: ListContent, oldLayout: ListLayout, oldViewport: CGFloat) {
        let newViewport = viewportHeight
        let top = Double(scrollOffset)
        func dirty(_ line: ListLayout.Line) {
            setNeedsDisplay(
                CGRect(x: 0, y: CGFloat(line.y) - scrollOffset, width: bounds.width, height: CGFloat(line.height)))
        }
        for index in layoutModel.lineIndices(overlapping: top, top + Double(newViewport)) {
            let line = layoutModel.lines[index]
            if !Self.has(line, of: content, in: oldLayout, of: old) { dirty(line) }
        }
        for index in oldLayout.lineIndices(overlapping: top, top + Double(oldViewport)) {
            let line = oldLayout.lines[index]
            if !Self.has(line, of: old, in: layoutModel, of: content) { dirty(line) }
        }
        // A cached typeset stays valid only while its row is unchanged.
        typesets = typesets.filter { index, _ in
            guard let new = Self.row(index, layoutModel, content), let previous = Self.row(index, oldLayout, old) else {
                return false
            }
            return new == previous
        }
        if newViewport < oldViewport {
            setNeedsDisplay(CGRect(x: 0, y: newViewport, width: bounds.width, height: oldViewport - newViewport))
        }
    }

    private static func row(_ index: Int, _ layout: ListLayout, _ content: ListContent) -> ListRow? {
        guard let line = layout.rowLine(index), case .row(let section, let row, _) = line.kind else { return nil }
        return content.sections[section].rows[row]
    }

    /// Whether `layout` shows exactly `line` (from `content`) at the same place.
    private static func has(
        _ line: ListLayout.Line, of content: ListContent, in layout: ListLayout, of other: ListContent
    ) -> Bool {
        guard let index = layout.lineIndices(overlapping: line.y, line.y + 0.5).first else { return false }
        let candidate = layout.lines[index]
        guard candidate.y == line.y, candidate.height == line.height else { return false }
        switch (line.kind, candidate.kind) {
        case (.header(let a), .header(let b)):
            return content.sections[a].title == other.sections[b].title
                && content.sections[a].count == other.sections[b].count
        case (.row(let sectionA, let rowA, let indexA), .row(let sectionB, let rowB, let indexB)):
            return indexA == indexB && content.sections[sectionA].rows[rowA] == other.sections[sectionB].rows[rowB]
        default:
            return false
        }
    }

    private func updateLens(animated: Bool) {
        guard let lens = selectionLens, let container = lens.view.superview else { return }
        guard let index = selectedRow, let rect = rowRect(index), let theme else {
            lens.isHidden = true
            return
        }
        let inset = CGFloat(theme.theme.lens.horizontalInset)
        let visible = rect.insetBy(dx: inset, dy: 0).intersection(
            CGRect(x: 0, y: 0, width: bounds.width, height: viewportHeight))
        guard visible.height > 1 else {
            lens.isHidden = true
            return
        }
        let wasHidden = lens.isHidden
        lens.move(to: convert(visible, to: container), animated: animated && !wasHidden)
        lens.isHidden = false
    }
}
