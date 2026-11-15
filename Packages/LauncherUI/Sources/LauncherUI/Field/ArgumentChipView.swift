import AppKit
import CoreText

/// One inline argument in the query row: a small inset field for text or secure text, or a
/// dropdown that opens its options as a menu inside the panel.
final class ArgumentChipView: NSView {
    /// The value changed: typed text, or a chosen option's id.
    var onChange: ((String) -> Void)?
    /// A field-editor command from a text chip, or a key from a dropdown chip mapped to one.
    var onCommand: ((Selector) -> Bool)?

    private(set) var argument: QueryArgument
    private var field: (any PanelField)?
    private var theme: ResolvedTheme?
    private var chevron: CGImage?
    private(set) var isFocused = false

    init(argument: QueryArgument) {
        self.argument = argument
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // The field keeps one width while the chip grows around it, and the chip clips it.
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        switch argument.kind {
        case .text: field = PanelTextField()
        case .secure: field = PanelSecureTextField()
        case .dropdown:
            setAccessibilityElement(true)
            setAccessibilityRole(.popUpButton)
        }
        if let field {
            field.stringValue = argument.value
            field.relay.onChange = { [weak self] text in
                self?.argument.value = text
                self?.onChange?(text)
            }
            field.relay.onCommand = { [weak self] selector in self?.onCommand?(selector) ?? false }
            field.relay.onEndEditing = { [weak self] in self?.showFocus(false) }
            field.onFocus = { [weak self] in self?.showFocus(true) }
            addSubview(field)
        }
        setAccessibilityLabel(argument.placeholder)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { field == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The view that takes focus when the chip is entered.
    var focusTarget: NSView { field ?? self }

    /// Where a text chip draws its typed text, for inspection. Secure chips show dots instead.
    var textFrame: CGRect? {
        guard case .text = argument.kind, let field else { return nil }
        return field.oneLineTextFrame.map { field.convert($0, to: self) }
    }

    /// Where the caret is in a text chip, and the text's length, for edge navigation.
    var caret: (location: Int, length: Int)? {
        guard let field, let editor = field.currentEditor() else { return nil }
        return (editor.selectedRange.location, (field.stringValue as NSString).length)
    }

    /// Takes a new value or placeholder from the host. A text chip keeps what is being typed.
    func update(_ argument: QueryArgument) {
        guard argument != self.argument else { return }
        self.argument = argument
        if let field, field.stringValue != argument.value { field.stringValue = argument.value }
        field?.setPlaceholder(argument.placeholder)
        setAccessibilityLabel(argument.placeholder)
        needsDisplay = true
    }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        let chips = theme.theme.chips
        layer?.cornerRadius = CGFloat(chips.cornerRadius)
        layer?.backgroundColor = theme.form.fieldFill
        field?.font = theme.form.chipFont
        field?.placeholderColor = NSColor(cgColor: theme.ghostText) ?? .tertiaryLabelColor
        field?.setPlaceholder(argument.placeholder)
        chevron = SymbolRenderer.image(
            "chevron.down", pointSize: CGFloat(chips.chevronSize), weight: .semibold, color: theme.subtitle,
            scale: window?.backingScaleFactor ?? 2)
        showFocus(isFocused)
        needsLayout = true
        needsDisplay = true
    }

    /// The width this chip wants: its text or placeholder, padded and clamped.
    var fittingWidth: CGFloat {
        guard let theme else { return 0 }
        let chips = theme.theme.chips
        let text = displayText.isEmpty ? argument.placeholder : displayText
        let font = theme.form.chipFont
        var width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + CGFloat(chips.padding) * 2
        if case .dropdown = argument.kind { width += CGFloat(chips.chevronSize) + CGFloat(chips.padding) / 2 }
        if case .secure = argument.kind, !argument.value.isEmpty {
            width = max(width, CGFloat(chips.minimumWidth))
        }
        return min(CGFloat(chips.maximumWidth), max(CGFloat(chips.minimumWidth), width + 4))
    }

    private var displayText: String {
        switch argument.kind {
        case .text: argument.value
        case .secure: String(repeating: "•", count: argument.value.count)
        case .dropdown(let options): options.first { $0.id == argument.value }?.title ?? ""
        }
    }

    private func showFocus(_ focused: Bool) {
        isFocused = focused
        guard let theme else { return }
        layer?.borderWidth = focused ? CGFloat(theme.theme.form.focusRingWidth) : 0
        layer?.borderColor = theme.form.focusRing
    }

    // MARK: Dropdown chips

    override func becomeFirstResponder() -> Bool {
        showFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        showFocus(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if field == nil {
            window?.makeFirstResponder(self)
            openMenu()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard field == nil, let chord = KeyChord(event: event) else { return super.keyDown(with: event) }
        let selector: Selector
        switch chord.key {
        case KeyChord.Key.space, KeyChord.Key.down:
            openMenu()
            return
        case KeyChord.Key.tab:
            selector =
                chord.modifiers.contains(.shift)
                ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
        case KeyChord.Key.left: selector = #selector(NSResponder.moveLeft(_:))
        case KeyChord.Key.right: selector = #selector(NSResponder.moveRight(_:))
        case KeyChord.Key.returnKey: selector = #selector(NSResponder.insertNewline(_:))
        case KeyChord.Key.escape: selector = #selector(NSResponder.cancelOperation(_:))
        case KeyChord.Key.delete: selector = #selector(NSResponder.deleteBackward(_:))
        case KeyChord.Key.up: selector = #selector(NSResponder.moveUp(_:))
        default: return
        }
        _ = onCommand?(selector)
    }

    /// Opens a dropdown chip's options under it, inside the panel.
    func openMenu() {
        guard case .dropdown(let options) = argument.kind, let surface = (window as? GlassPanel)?.surface,
            let glassContent = surface.glass.contentView
        else { return }
        let menu = DropdownMenuView(
            options: options, selectedID: argument.value,
            placement: .below(convert(bounds, to: glassContent), trailingAligned: false))
        menu.onChoose = { [weak self] option in
            guard let self else { return }
            argument.value = option.id
            needsDisplay = true
            onChange?(option.id)
        }
        surface.present(menu)
    }

    override func layout() {
        super.layout()
        guard let field, let theme else { return }
        let chips = theme.theme.chips
        let padding = CGFloat(chips.padding)
        let height = field.lineHeight
        // A fixed width: resizing a field while it is edited would select all of its text.
        field.setFrameIfChanged(
            CGRect(
                x: padding - 2, y: ((bounds.height - height) / 2).rounded(),
                width: CGFloat(chips.maximumWidth) - padding * 2 + 4, height: height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard field == nil, let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let chips = theme.theme.chips
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(chips.padding)
        var right = bounds.width - padding
        if let chevron {
            let size = CGFloat(chips.chevronSize)
            let frame = CGRect(
                x: right - size, y: RowTypesetter.snap((bounds.height - size) / 2, scale), width: size, height: size)
            RowRenderer.drawImage(chevron, in: frame, context: context)
            right = frame.minX - padding / 2
        }
        let font = theme.form.chipFont as CTFont
        let text = displayText
        let color = text.isEmpty ? theme.ghostText : theme.title
        let line = RowTypesetter.truncate(
            CTLineCreateWithAttributedString(
                RowTypesetter.attributed(text.isEmpty ? argument.placeholder : text, font: font, color: color)),
            to: max(0, right - padding), font: font, color: color)
        let baseline = RowTypesetter.snap(RowTypesetter.baseline(centering: font, in: bounds.height), scale)
        RowRenderer.draw(.init(line: line, origin: CGPoint(x: padding, y: baseline)), context)
    }

    override func accessibilityValue() -> Any? { displayText }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }
}
