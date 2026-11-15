import AppKit

/// The action panel: a card anchored above the action bar's bottom-right corner, with a filter
/// field on top and the selected item's actions below in sections, each with its shortcut.
///
/// Present it with `LauncherSurface.present(_:)`. Typing filters, Up and Down move, Return runs the
/// selected action, and Escape clears the filter or closes the card. The rest of the panel dims
/// while it is open. The card reports what happens; the host runs actions and closes the card.
public final class ActionCardView: CardSurface, PanelOverlay {
    /// The selected action should run.
    public var onActivate: ((ActionItem) -> Void)?
    /// The user closed the card with Escape. The card has already asked the surface to remove it.
    public var onCancel: (() -> Void)?
    /// The filter text changed. With `filtersItself` off, the host filters and calls `apply(_:)`.
    public var onQueryChange: ((String) -> Void)?
    /// Filters with `ActionCardContent.filtered(by:)` on every keystroke. Turn it off to filter
    /// with the engine instead.
    public var filtersItself = true
    public var overlaySizeDidChange: (() -> Void)?

    /// Every action, before filtering.
    public private(set) var content = ActionCardContent(sections: [])
    /// The filter text.
    public var query: String { filterField.stringValue }
    /// The action that Return would run.
    public var selectedItem: ActionItem? { list.selectedIndex.flatMap(list.item(at:)) }

    /// Selects the shown action at `index`, counted across sections.
    public func selectItem(at index: Int) {
        list.select(index)
    }

    /// Clears the filter text and, with `filtersItself` on, shows every action again with the first
    /// one selected. Call it before reusing the card, so a filter typed last time hides nothing. It
    /// does not call `onQueryChange`.
    public func clearFilter() {
        guard !query.isEmpty else { return }
        filterField.stringValue = ""
        guard filtersItself else { return }
        list.apply(content.sections)
        list.select(0)
    }

    let filterField = PanelTextField()
    let list = CardListView()
    private let divider = NSView()
    private var theme: ResolvedTheme?

    public init(content: ActionCardContent) {
        super.init(frame: .zero)
        divider.wantsLayer = true
        for view in [filterField, divider, list] as [NSView] { body.addSubview(view) }
        list.onActivate = { [weak self] index in self?.activate(index) }
        filterField.relay.onChange = { [weak self] text in self?.queryChanged(text) }
        filterField.relay.onCommand = { [weak self] selector in self?.perform(selector) ?? false }
        setAccessibilityLabel("Actions")
        apply(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows new actions, keeping the filter text. With `filtersItself` on, the filter applies
    /// to them at once.
    public func apply(_ content: ActionCardContent) {
        let shown = filtersItself ? content.filtered(by: query) : content
        let height = unfilteredRowsHeight
        self.content = content
        filterField.setPlaceholder(content.placeholder)
        list.apply(shown.sections)
        if unfilteredRowsHeight != height { overlaySizeDidChange?() }
        needsLayout = true
    }

    /// The rows' height for every action, unfiltered. The card keeps it while the user filters,
    /// so the filter field stays put and the nested glass is not resized on every keystroke.
    private var unfilteredRowsHeight: CGFloat {
        guard let theme else { return 0 }
        return CGFloat(CardListView.layout(content.sections, theme: theme, isMenu: false).viewportHeight)
    }

    // MARK: PanelOverlay

    public var placement: OverlayPlacement { .bottomTrailing }
    public var dimsBehind: Bool { true }
    public var focusView: NSView? { filterField }

    public func overlaySize(maximum: CGSize) -> CGSize {
        guard let theme else { return .zero }
        let card = theme.theme.card
        let height = CGFloat(card.filterHeight) + 1 + max(unfilteredRowsHeight, list.preferredHeight)
        return CGSize(width: min(maximum.width, CGFloat(card.width)), height: min(maximum.height, height))
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        applyChrome(theme, cornerRadius: theme.theme.card.cornerRadius)
        filterField.font = theme.card.filterFont
        filterField.placeholderColor = NSColor(cgColor: theme.ghostText) ?? .tertiaryLabelColor
        filterField.setPlaceholder(content.placeholder)
        divider.layer?.backgroundColor = theme.hairline
        list.apply(theme)
        needsLayout = true
    }

    public func overlayDidDismiss() {}

    public func prepareToShow() {
        layOutParts()
    }

    // MARK: Behaviour

    private func queryChanged(_ text: String) {
        onQueryChange?(text)
        guard filtersItself else { return }
        list.apply(content.filtered(by: text).sections)
        list.select(0)
    }

    private func perform(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): list.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): list.moveSelection(by: 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): list.moveToSection(forward: false)
        case #selector(NSResponder.moveToEndOfDocument(_:)): list.moveToSection(forward: true)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if let index = list.selectedIndex { activate(index) }
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty {
                dismissFromPanel()
                onCancel?()
            } else {
                filterField.stringValue = ""
                queryChanged("")
            }
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            break
        default:
            return false
        }
        return true
    }

    private func activate(_ index: Int) {
        guard let item = list.item(at: index) else { return }
        onActivate?(item)
    }

    override public func layout() {
        super.layout()
        layOutParts()
    }

    /// Places the filter field, the hairline and the rows for the current size.
    private func layOutParts() {
        guard let theme else { return }
        let card = theme.theme.card
        let padding = CGFloat(card.horizontalPadding)
        let filterHeight = CGFloat(card.filterHeight)
        let fieldHeight = filterField.lineHeight
        filterField.setFrameIfChanged(
            CGRect(
                x: padding - 2, y: ((filterHeight - fieldHeight) / 2).rounded(), width: bounds.width - padding * 2 + 4,
                height: fieldHeight))
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        divider.frame = CGRect(x: 0, y: filterHeight, width: bounds.width, height: hairline)
        list.frame = CGRect(
            x: 0, y: filterHeight + 1, width: bounds.width, height: max(0, bounds.height - filterHeight - 1))
    }
}
