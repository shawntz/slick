import AppKit

/// A list of options drawn as a small card inside the panel, under the control that opened it:
/// a filter chip, an argument chip or a form dropdown. The selected option has a checkmark.
///
/// Up and Down move, Return or Space chooses, Escape closes, and typing jumps to the first option
/// that starts with what was typed. Choosing or closing removes the menu.
public final class DropdownMenuView: CardSurface, PanelOverlay {
    /// An option was chosen. The menu has already asked the surface to remove it.
    public var onChoose: ((MenuOption) -> Void)?
    /// The menu closed without a choice.
    public var onCancel: (() -> Void)?
    public var overlaySizeDidChange: (() -> Void)?
    public let options: [MenuOption]
    public let placement: OverlayPlacement

    let list = CardListView()
    private var theme: ResolvedTheme?
    private var typed = ""
    private var lastTyped: TimeInterval = 0
    private var chosen = false

    /// A menu of `options` with `selectedID` checked, placed by `placement`.
    public init(options: [MenuOption], selectedID: String?, placement: OverlayPlacement) {
        self.options = options
        self.placement = placement
        super.init(frame: .zero)
        list.isMenu = true
        body.addSubview(list)
        var sections: [ActionSection] = []
        for option in options {
            let item = ActionItem(
                id: option.id, title: option.title, icon: option.icon, isChecked: option.id == selectedID)
            if let last = sections.last, last.title == option.section {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(ActionSection(title: option.section, items: [item]))
            }
        }
        list.apply(sections)
        list.select(options.firstIndex { $0.id == selectedID } ?? 0)
        list.onActivate = { [weak self] index in self?.choose(index) }
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var acceptsFirstResponder: Bool { true }

    override public func keyDown(with event: NSEvent) {
        guard let chord = KeyChord(event: event) else { return }
        switch chord.key {
        case KeyChord.Key.up: list.moveSelection(by: -1)
        case KeyChord.Key.down: list.moveSelection(by: 1)
        case KeyChord.Key.returnKey, KeyChord.Key.space:
            if let index = list.selectedIndex { choose(index) }
        case KeyChord.Key.escape: cancelOperation(nil)
        default:
            guard chord.modifiers.isDisjoint(with: [.command, .control]), let text = event.characters, !text.isEmpty
            else { return }
            typeSelect(text, at: event.timestamp)
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        dismissFromPanel()
    }

    /// Jumps to the first option starting with the letters typed in quick succession.
    private func typeSelect(_ text: String, at time: TimeInterval) {
        typed = time - lastTyped < 1 ? typed + text : text
        lastTyped = time
        let needle = typed.lowercased()
        if let index = options.firstIndex(where: { $0.title.lowercased().hasPrefix(needle) }) { list.select(index) }
    }

    private func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        chosen = true
        dismissFromPanel()
        onChoose?(options[index])
    }

    // MARK: PanelOverlay

    public var dimsBehind: Bool { false }
    public var focusView: NSView? { self }

    public func overlayDidDismiss() {
        if !chosen { onCancel?() }
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        applyChrome(theme, cornerRadius: theme.theme.card.menuCornerRadius)
        list.apply(theme)
        needsLayout = true
    }

    public func overlaySize(maximum: CGSize) -> CGSize {
        guard let theme else { return .zero }
        var width = CGFloat(theme.theme.card.menuWidth)
        if case .below(let anchor, _) = placement { width = max(width, anchor.width) }
        return CGSize(width: min(maximum.width, width), height: min(maximum.height, list.preferredHeight))
    }

    override public func layout() {
        super.layout()
        list.frame = bounds
    }
}
