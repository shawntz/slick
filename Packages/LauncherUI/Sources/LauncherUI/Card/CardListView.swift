import AppKit
import CoreText

/// The rows of a card or menu: section titles, then rows with an icon, a title and keycaps or a
/// checkmark, drawn with Core Text in one view. The selected row gets a soft fill.
///
/// A single click runs a row, as in any menu. There is no hover highlight, as in the list.
final class CardListView: NSView {
    /// A row was clicked or pressed through accessibility.
    var onActivate: ((Int) -> Void)?
    /// Menus use the shorter menu row height.
    var isMenu = false {
        didSet { if isMenu != oldValue { relayout() } }
    }

    private(set) var sections: [ActionSection] = []
    private(set) var selectedIndex: Int?
    private(set) var scrollOffset: CGFloat = 0
    private(set) var layoutModel = ListLayout(content: .empty, metrics: Theme.standard.list, maxHeight: 0)
    private(set) var theme: ResolvedTheme?
    private var symbols: [String: CGImage] = [:]
    private static let symbolCacheLimit = 64
    private(set) var hasIcons = false
    /// Rows across sections. Selection uses it, so it works before the first layout.
    private var itemCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        setAccessibilityElement(true)
        setAccessibilityRole(isMenu ? .menu : .list)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        // Rendered symbols are keyed by colour, so they stay valid across themes; only bound them.
        if symbols.count > Self.symbolCacheLimit { symbols.removeAll() }
        relayout()
        if let selectedIndex { reveal(selectedIndex) }
        needsDisplay = true
    }

    /// Shows new rows. The selection moves to the first row when its row is gone.
    func apply(_ sections: [ActionSection]) {
        guard sections != self.sections else { return }
        self.sections = sections
        hasIcons = sections.contains { $0.items.contains { $0.icon != nil } }
        itemCount = sections.reduce(0) { $0 + $1.items.count }
        relayout()
        scrollOffset = min(scrollOffset, CGFloat(layoutModel.maxScrollOffset))
        if selectedIndex.map({ $0 >= itemCount }) ?? true {
            selectedIndex = itemCount > 0 ? 0 : nil
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The height the rows need, up to the theme's visible row limit.
    var preferredHeight: CGFloat { CGFloat(layoutModel.viewportHeight) }

    func item(at index: Int) -> ActionItem? {
        var remaining = index
        for section in sections {
            if remaining < section.items.count { return remaining >= 0 ? section.items[remaining] : nil }
            remaining -= section.items.count
        }
        return nil
    }

    var rowCount: Int { itemCount }

    func select(_ index: Int?) {
        let target = index.flatMap { $0 >= 0 && $0 < itemCount ? $0 : nil }
        guard target != selectedIndex else { return }
        if let old = selectedIndex, let rect = rowRect(old) { setNeedsDisplay(rect) }
        selectedIndex = target
        if let target {
            reveal(target)
            if let rect = rowRect(target) { setNeedsDisplay(rect) }
        }
    }

    /// Moves the selection by `delta` rows, wrapping at either end as menus do.
    func moveSelection(by delta: Int) {
        let count = itemCount
        guard count > 0 else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : count)
        select(((current + delta) % count + count) % count)
    }

    /// Moves to the first row of the next or previous section.
    func moveToSection(forward: Bool) {
        let current = selectedIndex ?? 0
        if let target = forward
            ? layoutModel.nextSectionStart(after: current) : layoutModel.previousSectionStart(before: current)
        {
            select(target)
        }
    }

    /// Row `index` in view coordinates.
    func rowRect(_ index: Int) -> CGRect? {
        guard let line = layoutModel.rowLine(index) else { return nil }
        return CGRect(x: 0, y: CGFloat(line.y) - scrollOffset, width: bounds.width, height: CGFloat(line.height))
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = layoutModel.rowIndex(atY: Double(point.y + scrollOffset)) else { return }
        select(index)
        onActivate?(index)
    }

    override func scrollWheel(with event: NSEvent) {
        guard layoutModel.maxScrollOffset > 0, let theme else { return }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= CGFloat(theme.theme.list.wheelLineHeight) }
        scroll(to: scrollOffset - delta)
    }

    private func scroll(to offset: CGFloat) {
        let clamped = min(max(0, offset), CGFloat(layoutModel.maxScrollOffset)).rounded()
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        needsDisplay = true
    }

    private func reveal(_ index: Int) {
        guard let line = layoutModel.rowLine(index) else { return }
        let viewport = CGFloat(layoutModel.viewportHeight)
        if CGFloat(line.y) < scrollOffset {
            scroll(to: CGFloat(line.y))
        } else if CGFloat(line.maxY) > scrollOffset + viewport {
            scroll(to: CGFloat(line.maxY) - viewport)
        }
    }

    // MARK: Drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func relayout() {
        guard let theme else { return }
        layoutModel = Self.layout(sections, theme: theme, isMenu: isMenu)
    }

    /// Where the rows of `sections` go with the card metrics: the list's layout with card row,
    /// header and padding sizes.
    static func layout(_ sections: [ActionSection], theme: ResolvedTheme, isMenu: Bool) -> ListLayout {
        let card = theme.theme.card
        var metrics = theme.theme.list
        metrics.rowHeight = isMenu ? card.menuRowHeight : card.rowHeight
        metrics.sectionHeaderHeight = card.sectionHeaderHeight
        metrics.verticalPadding = card.verticalPadding
        metrics.maxVisibleRows = card.maxVisibleRows
        let content = ListContent(
            sections: sections.map { section in
                ListSection(title: section.title, rows: section.items.map { _ in ListRow(id: 0, title: "") })
            })
        return ListLayout(content: content, metrics: metrics, maxHeight: .greatestFiniteMagnitude)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let minY = Double(dirtyRect.minY + scrollOffset)
        let maxY = Double(dirtyRect.maxY + scrollOffset)
        for lineIndex in layoutModel.lineIndices(overlapping: minY, maxY) {
            let line = layoutModel.lines[lineIndex]
            let rect = CGRect(
                x: 0, y: CGFloat(line.y) - scrollOffset, width: bounds.width, height: CGFloat(line.height))
            switch line.kind {
            case .header(let section):
                drawHeader(sections[section].title ?? "", in: rect, theme: theme, context: context, scale: scale)
            case .row(let section, let row, let index):
                drawRow(
                    sections[section].items[row], in: rect, selected: index == selectedIndex, theme: theme,
                    context: context, scale: scale)
            }
        }
    }

    private func drawHeader(_ title: String, in rect: CGRect, theme: ResolvedTheme, context: CGContext, scale: CGFloat)
    {
        let card = theme.theme.card
        let line = CTLineCreateWithAttributedString(
            RowTypesetter.attributed(title, font: theme.card.sectionFont, color: theme.sectionHeader))
        let origin = CGPoint(
            x: CGFloat(card.horizontalPadding),
            y: RowTypesetter.snap(rect.minY + CGFloat(card.sectionHeaderBaseline), scale))
        RowRenderer.draw(.init(line: line, origin: origin), context)
    }

    private func drawRow(
        _ item: ActionItem, in rect: CGRect, selected: Bool, theme: ResolvedTheme, context: CGContext, scale: CGFloat
    ) {
        let card = theme.theme.card
        if selected {
            let fill = rect.insetBy(dx: CGFloat(card.selectionInset), dy: 0)
            let radius = CGFloat(card.selectionCornerRadius)
            context.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(theme.card.selection)
            context.fillPath()
        }
        let color = item.isDestructive ? theme.card.destructive : theme.title
        var x = CGFloat(card.horizontalPadding)
        let iconSize = CGFloat(card.iconSize)
        if hasIcons {
            let frame = CGRect(
                x: x, y: RowTypesetter.snap(rect.minY + (rect.height - iconSize) / 2, scale), width: iconSize,
                height: iconSize)
            if let image = icon(item.icon, destructive: item.isDestructive, size: iconSize, theme: theme, scale: scale)
            {
                RowRenderer.drawImage(image, in: frame, context: context)
            }
            x += iconSize + CGFloat(card.iconGap)
        }

        var right = rect.maxX - CGFloat(card.horizontalPadding)
        if item.isChecked,
            let check = symbol("checkmark", color: theme.title, size: iconSize, theme: theme, scale: scale)
        {
            let frame = CGRect(
                x: right - iconSize, y: RowTypesetter.snap(rect.minY + (rect.height - iconSize) / 2, scale),
                width: iconSize, height: iconSize)
            RowRenderer.drawImage(check, in: frame, context: context)
            right = frame.minX - CGFloat(card.iconGap)
        }
        right = KeycapRenderer.draw(
            item.keys, right: right, top: rect.minY, height: rect.height, theme: theme, context: context, scale: scale)

        let font = theme.card.rowFont
        let string =
            item.isDestructive
            ? RowTypesetter.attributed(item.title, font: font, color: color)
            : RowTypesetter.emphasized(
                item.title, highlights: item.titleHighlights, emphasizesMatches: true, font: font, theme: theme)
        let line = RowTypesetter.truncate(
            CTLineCreateWithAttributedString(string), to: max(0, right - x - CGFloat(card.iconGap)), font: font,
            color: color)
        let baseline = RowTypesetter.snap(rect.minY + RowTypesetter.baseline(centering: font, in: rect.height), scale)
        RowRenderer.draw(.init(line: line, origin: CGPoint(x: x, y: baseline)), context)
    }

    private func icon(_ icon: CardIcon?, destructive: Bool, size: CGFloat, theme: ResolvedTheme, scale: CGFloat)
        -> CGImage?
    {
        switch icon {
        case .image(let image): image
        case .symbol(let name):
            symbol(
                name, color: destructive ? theme.card.destructive : theme.subtitle, size: size, theme: theme,
                scale: scale)
        case nil: nil
        }
    }

    private func symbol(_ name: String, color: CGColor, size: CGFloat, theme: ResolvedTheme, scale: CGFloat) -> CGImage?
    {
        let key = "\(name)|\(color.hashValue)|\(size)|\(scale)"
        if let cached = symbols[key] { return cached }
        let image = SymbolRenderer.image(name, pointSize: size, color: color, scale: scale)
        symbols[key] = image
        return image
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var elements: [NSAccessibilityElement] = []
        var index = 0
        for section in sections {
            for item in section.items {
                elements.append(CardRowElement(index: index, item: item, list: self))
                index += 1
            }
        }
        return elements
    }

    func accessibilityActivate(_ index: Int) {
        select(index)
        onActivate?(index)
    }
}

/// One card row as accessibility clients see it.
nonisolated final class CardRowElement: NSAccessibilityElement {
    let index: Int
    private weak var list: CardListView?

    @MainActor init(index: Int, item: ActionItem, list: CardListView) {
        self.index = index
        self.list = list
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(list)
        setAccessibilityLabel(item.title)
        if !item.keys.isEmpty { setAccessibilityHelp(item.keys.joined()) }
        setAccessibilitySelected(item.isChecked)
    }

    override func accessibilityFrameInParentSpace() -> NSRect {
        let (list, index) = (list, index)
        return MainActor.assumeIsolated {
            guard let list, let rect = list.rowRect(index) else { return .zero }
            return CGRect(x: rect.minX, y: list.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let (list, index) = (list, index)
        return MainActor.assumeIsolated {
            list?.accessibilityActivate(index)
            return list != nil
        }
    }
}
