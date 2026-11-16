import AppKit

/// A grid of cells under optional section headers: one view that draws every visible cell with
/// Core Text, like `ResultListView`.
///
/// Updates are diffed per cell, so a cell that looks the same at the same place is not redrawn,
/// and typesetting is cached by what a cell shows, so a cell that moves as a query narrows is not
/// typeset again. The layout keeps one block per section rather than a frame per cell, so
/// filtering thousands of cells costs what the visible cells cost. Selection moves in two
/// dimensions; the panel's lens follows it.
///
/// Image cells draw fastest. A glyph cell typesets its emoji with Core Text on every draw, which
/// costs about as much as the rest of the cell; for large emoji sets, hand the grid pre-rendered
/// images from the icon atlas, as the list's icons are.
public final class GridView: NSView, LauncherContentView {
    /// The selected cell changed by a click or an accessibility action. Changes made through
    /// `select(_:animated:)` or `moveSelection(_:animated:)` are not reported.
    public var onSelect: ((Int) -> Void)?
    /// A cell was double-clicked or pressed through accessibility.
    public var onActivate: ((Int) -> Void)?
    /// Scrolling changed which cells are visible: the wheel, a selection scrolled into view, or
    /// `scroll(to:)`. It gets the cells now visible, counted across sections. `apply(_:)` does not
    /// call it; read `visibleCells` after new content instead.
    public var onVisibleCellsChange: ((Range<Int>) -> Void)?
    public var contentHeightDidChange: (() -> Void)?
    public weak var selectionLens: SelectionLens? {
        didSet {
            applyLensRadius()
            updateLens(animated: false)
        }
    }

    public private(set) var content: GridContent = .empty
    /// The selected cell, counted across sections.
    public private(set) var selectedIndex: Int?
    /// How far the content is scrolled, in points.
    public private(set) var scrollOffset: CGFloat = 0

    /// Display passes so far, and cells drawn by the last one. Tests read them to check diffing.
    private(set) var displayPasses = 0
    private(set) var cellsDrawnInLastPass = 0

    private(set) var layoutModel = GridLayout(
        content: .empty, metrics: Theme.standard.grid, list: Theme.standard.list, width: 0, maxHeight: 0)
    private(set) var theme: ResolvedTheme?
    /// Typeset cells by what they show, not where: while a query narrows, cells move to new
    /// places and keep their typesetting.
    private var typesets: [GridCellKey: GridCellTypeset] = [:]
    private var glyphFont: CTFont?
    private let indicator = ScrollIndicatorView()
    var accessibilityCache: [NSAccessibilityElement]?
    /// The visible cells last reported through `onVisibleCellsChange`.
    /// Nil after new content: the next scroll reports.
    private var reportedVisibleCells: Range<Int>?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        indicator.isHidden = true
        addSubview(indicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public var acceptsFirstResponder: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        min(limit, CGFloat(layoutModel.viewportHeight))
    }

    var viewportHeight: CGFloat { min(bounds.height, CGFloat(layoutModel.viewportHeight)) }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        typesets.removeAll(keepingCapacity: true)
        indicator.apply(theme)
        relayout()
        applyLensRadius()
        needsDisplay = true
        updateLens(animated: false)
    }

    /// Shows new content. Cells that look the same as before at the same place are not redrawn.
    /// The selection is kept when its index still exists and cleared otherwise.
    public func apply(_ newContent: GridContent) {
        guard newContent != content else { return }
        let old = content
        let oldLayout = layoutModel
        let oldOffset = scrollOffset
        let oldViewport = viewportHeight
        content = newContent
        relayout()
        scrollOffset = min(scrollOffset, CGFloat(layoutModel.maxScrollOffset))
        if let index = selectedIndex, index >= layoutModel.cellCount { selectedIndex = nil }

        let reshaped = !old.hasSameShape(as: newContent) || oldLayout.cellWidth != layoutModel.cellWidth
        if reshaped { typesets.removeAll(keepingCapacity: true) }
        if reshaped || oldOffset != scrollOffset {
            setNeedsDisplay(bounds)
        } else {
            invalidateChangedCells(old: old, oldLayout: oldLayout, oldViewport: oldViewport)
        }
        if accessibilityCache != nil {
            accessibilityCache = nil
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        indicator.update(offset: scrollOffset, content: layoutModel.contentHeight, viewport: viewportHeight)
        updateLens(animated: false)
        reportedVisibleCells = nil
        if oldLayout.viewportHeight != layoutModel.viewportHeight { contentHeightDidChange?() }
    }

    /// The cells at least partly inside the visible height, from the first to the last, counted
    /// across sections.
    public var visibleCells: Range<Int> {
        let top = Double(scrollOffset)
        let cells = layoutModel.cells(overlapping: top, top + Double(viewportHeight))
        guard let first = cells.first, let last = cells.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// Fills in the image of every image cell with `id`, redrawing only those cells.
    public func setImage(_ image: CGImage?, forCell id: UInt64) {
        var index = 0
        for section in content.sections.indices {
            for item in content.sections[section].cells.indices {
                if content.sections[section].cells[item].id == id,
                    case .image = content.sections[section].cells[item].content
                {
                    content.sections[section].cells[item].content = .image(image)
                    if let rect = cellRect(index) { setNeedsDisplay(rect) }
                }
                index += 1
            }
        }
    }

    /// The cell at `index`, counted across sections.
    public func cell(at index: Int) -> GridCell? {
        Self.cell(index, layoutModel, content)
    }

    /// The frame of cell `index` (tile and title) in view coordinates, scrolled into view or not.
    public func cellRect(_ index: Int) -> CGRect? {
        layoutModel.cellFrame(index).map { $0.offsetBy(dx: 0, dy: -scrollOffset) }
    }

    /// The number of columns the grid lays out now.
    public var columnCount: Int { layoutModel.columns }

    // MARK: Selection

    /// Selects cell `index`, or nothing, scrolling it into view.
    public func select(_ index: Int?, animated: Bool) {
        guard let index, index >= 0, index < layoutModel.cellCount else {
            selectedIndex = nil
            updateLens(animated: false)
            return
        }
        let changed = selectedIndex != index
        selectedIndex = index
        if changed, accessibilityCache != nil {
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
        scrollToReveal(index)
        updateLens(animated: animated)
    }

    /// Moves the selection one step. With nothing selected, any move selects the first cell.
    /// Returns the new selection, or nil when the move hit an edge.
    @discardableResult
    public func moveSelection(_ direction: GridDirection, animated: Bool = true) -> Int? {
        guard layoutModel.cellCount > 0 else { return nil }
        guard let current = selectedIndex else {
            select(0, animated: false)
            return 0
        }
        guard let target = layoutModel.target(from: current, moving: direction) else { return nil }
        select(target, animated: animated)
        return target
    }

    /// Moves the selection to the first cell of the next or previous section.
    @discardableResult
    public func moveSelectionToSection(forward: Bool, animated: Bool = true) -> Int? {
        let current = selectedIndex ?? 0
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
        let visible = visibleCells
        guard visible != reportedVisibleCells else { return }
        reportedVisibleCells = visible
        onVisibleCellsChange?(visible)
    }

    override public func scrollWheel(with event: NSEvent) {
        guard layoutModel.maxScrollOffset > 0, let theme else { return }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= CGFloat(theme.theme.list.wheelLineHeight) }
        scroll(to: scrollOffset - delta)
        indicator.flash()
    }

    private func scrollToReveal(_ index: Int) {
        guard let frame = layoutModel.cellFrame(index), let theme else { return }
        let padding = CGFloat(theme.theme.grid.verticalPadding)
        var top = frame.minY
        // Bring the section header along when revealing a section's first row.
        if let blockIndex = layoutModel.blockIndex(of: index) {
            let block = layoutModel.blocks[blockIndex]
            if index - block.start < layoutModel.columns, let header = block.headerY { top = CGFloat(header) }
        }
        if top - padding < scrollOffset {
            scroll(to: top - padding)
        } else if frame.maxY + padding > scrollOffset + viewportHeight {
            scroll(to: frame.maxY + padding - viewportHeight)
        }
    }

    // MARK: Pointer

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < viewportHeight,
            let index = layoutModel.cellIndex(atX: Double(point.x), y: Double(point.y + scrollOffset))
        else { return }
        if event.clickCount >= 2 {
            onActivate?(index)
        } else {
            select(index, animated: true)
            onSelect?(index)
        }
    }

    // MARK: Drawing

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        typesets.removeAll(keepingCapacity: true)
        relayout()
        indicator.update(offset: scrollOffset, content: layoutModel.contentHeight, viewport: viewportHeight)
        setNeedsDisplay(bounds)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        typesets.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        displayPasses += 1
        cellsDrawnInLastPass = 0
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        context.touchCorners(of: bounds)
        let viewport = viewportHeight
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: viewport))
        let scale = window?.backingScaleFactor ?? 2
        let minY = Double(max(dirtyRect.minY, 0) + scrollOffset)
        let maxY = Double(min(dirtyRect.maxY, viewport) + scrollOffset)
        for header in layoutModel.headers(overlapping: minY, maxY) {
            RowRenderer.drawHeader(
                content.sections[header.section].headerText ?? "", top: CGFloat(header.y) - scrollOffset,
                in: context, theme: theme, scale: scale)
        }
        for index in layoutModel.cells(overlapping: minY, maxY) {
            guard let frame = cellRect(index), needsToDraw(frame), let cell = cell(at: index) else { continue }
            GridCellRenderer.draw(
                cell, typeset: typeset(index, cell, scale: scale), at: frame.origin, layout: layoutModel,
                in: context, theme: theme, roundsImages: content.columns != .glyph)
            cellsDrawnInLastPass += 1
        }
    }

    // MARK: Internals

    private func relayout() {
        guard let theme else { return }
        let old = layoutModel
        layoutModel = GridLayout(
            content: content, metrics: theme.theme.grid, list: theme.theme.list, width: Double(bounds.width),
            maxHeight: Double(bounds.height))
        if old.cellWidth != layoutModel.cellWidth || old.cellHeight != layoutModel.cellHeight {
            typesets.removeAll(keepingCapacity: true)
        }
        let glyphSize = CGFloat(layoutModel.tileHeight * theme.theme.grid.glyphScale)
        if glyphFont.map({ CTFontGetSize($0) }) != glyphSize {
            glyphFont = NSFont.systemFont(ofSize: max(1, glyphSize)) as CTFont
            typesets.removeAll(keepingCapacity: true)
        }
    }

    func typeset(_ index: Int, _ cell: GridCell, scale: CGFloat) -> GridCellTypeset {
        let key = GridCellKey(cell, emphasizesMatches: content.emphasizesMatches)
        if let cached = typesets[key] { return cached }
        guard let theme, let glyphFont else { return GridCellTypeset() }
        // Scrolling through a large grid would otherwise keep every cell it ever showed.
        if typesets.count >= Self.typesetCacheLimit { typesets.removeAll(keepingCapacity: true) }
        let typeset = GridCellRenderer.typeset(
            cell, layout: layoutModel, showsTitles: content.showsTitles, emphasizesMatches: content.emphasizesMatches,
            glyphFont: glyphFont, theme: theme, scale: scale)
        typesets[key] = typeset
        return typeset
    }

    /// Marks the cells and headers whose look changed. A cell is clean when the old content had
    /// the same cell at the same place.
    private func invalidateChangedCells(old: GridContent, oldLayout: GridLayout, oldViewport: CGFloat) {
        let top = Double(scrollOffset)
        let newViewport = viewportHeight
        func dirty(_ frame: CGRect) { setNeedsDisplay(frame.offsetBy(dx: 0, dy: -scrollOffset)) }
        for index in layoutModel.cells(overlapping: top, top + Double(newViewport)) {
            guard let frame = layoutModel.cellFrame(index) else { continue }
            if oldLayout.cellFrame(index) != frame
                || Self.cell(index, oldLayout, old) != Self.cell(index, layoutModel, content)
            {
                dirty(frame)
            }
        }
        for index in oldLayout.cells(overlapping: top, top + Double(oldViewport)) {
            guard let frame = oldLayout.cellFrame(index) else { continue }
            if index >= layoutModel.cellCount || layoutModel.cellFrame(index) != frame { dirty(frame) }
        }
        // A header is clean when the same text sits at the same place before and after.
        let oldHeaders = Set(
            oldLayout.headers(overlapping: top, top + Double(oldViewport)).map {
                HeaderMark(y: $0.y, text: old.sections[$0.section].headerText)
            })
        let newHeaders = Set(
            layoutModel.headers(overlapping: top, top + Double(newViewport)).map {
                HeaderMark(y: $0.y, text: content.sections[$0.section].headerText)
            })
        for header in oldHeaders.symmetricDifference(newHeaders) {
            setNeedsDisplay(
                CGRect(
                    x: 0, y: CGFloat(header.y) - scrollOffset, width: bounds.width,
                    height: CGFloat(layoutModel.headerHeight)))
        }
        if newViewport < oldViewport {
            setNeedsDisplay(CGRect(x: 0, y: newViewport, width: bounds.width, height: oldViewport - newViewport))
        }
    }

    /// Typeset cells kept before the cache starts over: several screens of the densest grid.
    private static let typesetCacheLimit = 512

    private static func cell(_ index: Int, _ layout: GridLayout, _ content: GridContent) -> GridCell? {
        guard let location = layout.location(of: index) else { return nil }
        return content.sections[location.section].cells[location.item]
    }

    /// The tile part of a cell rectangle.
    private func tileRect(_ cell: CGRect) -> CGRect {
        CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: CGFloat(layoutModel.tileHeight))
    }

    private func applyLensRadius() {
        guard let theme else { return }
        selectionLens?.cornerRadius = CGFloat(theme.theme.grid.lensCornerRadius)
    }

    private func updateLens(animated: Bool) {
        guard let lens = selectionLens, let container = lens.view.superview else { return }
        // The lens wraps the tile, not the title: over a bright image the lens glass lightens,
        // and the title stays on the panel glass where its contrast is known.
        guard let index = selectedIndex, let rect = cellRect(index).map({ tileRect($0) }), let theme else {
            lens.isHidden = true
            return
        }
        let outset = CGFloat(theme.theme.grid.lensOutset)
        let visible = rect.insetBy(dx: -outset, dy: -outset).intersection(
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

/// A section header's place and text, for diffing.
private struct HeaderMark: Hashable {
    var y: Double
    var text: String?
}

/// What a cell's typesetting depends on, so a typeset can follow its cell as it moves.
private struct GridCellKey: Hashable {
    let id: UInt64
    let title: String
    let subtitle: String
    let highlights: [HighlightRange]
    let glyph: String?
    let color: ThemeColor?
    /// The image itself, by identity: a cell whose image arrives looks different.
    let image: ObjectIdentifier?

    /// Highlights count only while matches are emphasized; otherwise they do not change the look.
    init(_ cell: GridCell, emphasizesMatches: Bool) {
        id = cell.id
        title = cell.title
        subtitle = cell.subtitle
        highlights = emphasizesMatches ? cell.titleHighlights : []
        switch cell.content {
        case .glyph(let text): (glyph, color, image) = (text, nil, nil)
        case .color(let swatch): (glyph, color, image) = (nil, swatch, nil)
        case .image(let picture): (glyph, color, image) = (nil, nil, picture.map(ObjectIdentifier.init))
        }
    }
}
