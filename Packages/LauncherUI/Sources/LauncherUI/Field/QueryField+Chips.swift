import AppKit

/// The query row's argument chips and filter dropdown.
extension QueryField {
    /// The arguments' current values, in order: typed text, or chosen option ids.
    public var argumentValues: [String] { argumentChips.map(\.argument.value) }

    /// The argument with keyboard focus, or nil while the query text has it.
    public var focusedArgument: Int? { argumentChips.firstIndex(where: \.isFocused) }

    /// Moves keyboard focus to argument `index`, or back to the query text when nil.
    public func focusArgument(_ index: Int?) {
        guard let index, argumentChips.indices.contains(index) else {
            window?.makeFirstResponder(textField)
            let end = (textField.stringValue as NSString).length
            textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            return
        }
        // Size the chips first: resizing a field that is being edited would end its editing.
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(argumentChips[index].focusTarget)
    }

    /// Opens the filter dropdown's options inside the panel. Hosts call this for Command-P.
    public func openFilterMenu() {
        filterChip?.openMenu()
    }

    // MARK: Building

    func rebuildArgumentChips() {
        let limit = theme?.theme.chips.maxArguments ?? Theme.standard.chips.maxArguments
        let shown = Array(arguments.prefix(limit))
        if shown.map(\.kind) == argumentChips.map(\.argument.kind) {
            for (chip, argument) in zip(argumentChips, shown) { chip.update(argument) }
        } else {
            let hadFocus = focusedArgument != nil
            for chip in argumentChips { chip.removeFromSuperview() }
            argumentChips = shown.enumerated().map { index, argument in makeChip(argument, index: index) }
            if hadFocus { focusArgument(nil) }
        }
        needsLayout = true
        placeArgumentChips()
        placeGhost()
    }

    private func makeChip(_ argument: QueryArgument, index: Int) -> ArgumentChipView {
        let chip = ArgumentChipView(argument: argument)
        if let theme { chip.apply(theme) }
        chip.onChange = { [weak self] value in
            guard let self else { return }
            placeArgumentChips()
            delegate?.queryField(self, argumentAt: index, didChange: value)
        }
        chip.onCommand = { [weak self] selector in self?.chipCommand(selector, at: index) ?? false }
        addSubview(chip)
        return chip
    }

    func rebuildFilterChip() {
        if let filter {
            if let filterChip {
                filterChip.update(filter)
            } else {
                let chip = FilterChipView(filter: filter)
                if let theme { chip.apply(theme) }
                chip.onChoose = { [weak self] option in
                    guard let self else { return }
                    self.filter?.selectedID = option.id
                    delegate?.queryField(self, didChooseFilter: option)
                }
                addSubview(chip)
                filterChip = chip
            }
        } else {
            filterChip?.removeFromSuperview()
            filterChip = nil
        }
        needsLayout = true
    }

    // MARK: Layout

    /// Puts the chips right after the text, or as far right as they fit. Runs on every keystroke
    /// while arguments show, so it only sets frames.
    func placeArgumentChips() {
        guard !argumentChips.isEmpty, let theme else {
            textField.layer?.mask = nil
            return
        }
        let chips = theme.theme.chips
        let spacing = CGFloat(chips.spacing)
        let widths = argumentChips.map(\.fittingWidth)
        let total = widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
        let shown = textField.stringValue.isEmpty ? textField.placeholderAttributedString?.string ?? "" : text
        let textWidth = ceil((shown as NSString).size(withAttributes: [.font: theme.queryFont]).width) + 4
        let area = textArea
        var x = max(area.minX, min(area.minX + textWidth + spacing, area.maxX - total))
        // Long text ends before the chips under a mask. A narrower frame would do the same, but
        // resizing the field while it is edited ends its editing and selects all of its text.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.frame = CGRect(x: 0, y: 0, width: max(0, x - spacing - area.minX + 2), height: textField.bounds.height)
        textField.layer?.mask = textMask
        CATransaction.commit()
        let height = CGFloat(chips.height)
        for (chip, width) in zip(argumentChips, widths) {
            chip.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            x += width + spacing
        }
    }

    // MARK: Keys

    /// Moves between chips at their edges and passes Return, Escape, Up and Down to the host.
    private func chipCommand(_ selector: Selector, at index: Int) -> Bool {
        let chip = argumentChips[index]
        let caret = chip.caret
        let atStart = caret.map { $0.location == 0 } ?? true
        let atEnd = caret.map { $0.location >= $0.length } ?? true
        let modifiers = NSApp.currentEvent.flatMap { KeyChord(event: $0)?.modifiers } ?? []
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if index + 1 < argumentChips.count { focusArgument(index + 1) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            focusArgument(index > 0 ? index - 1 : nil)
            return true
        case #selector(NSResponder.moveLeft(_:)) where atStart:
            focusArgument(index > 0 ? index - 1 : nil)
            return true
        case #selector(NSResponder.moveRight(_:)) where atEnd:
            if index + 1 < argumentChips.count { focusArgument(index + 1) }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where chip.argument.value.isEmpty:
            focusArgument(index > 0 ? index - 1 : nil)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            _ = delegate?.queryField(self, perform: .submit(modifiers))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            _ = delegate?.queryField(self, perform: .cancel(modifiers))
            return true
        case #selector(NSResponder.moveUp(_:)):
            return delegate?.queryField(self, perform: .moveUp) ?? false
        case #selector(NSResponder.moveDown(_:)):
            return delegate?.queryField(self, perform: .moveDown) ?? false
        default:
            return false
        }
    }
}

/// The glyph in the leading slot. As a back chevron it is a button: a click, or a press through
/// accessibility, asks the host to go back.
final class LeadingGlyphView: NSImageView {
    var onPress: (() -> Void)?
    var isBackButton = false {
        didSet {
            setAccessibilityElement(isBackButton)
            setAccessibilityRole(isBackButton ? .button : .image)
            setAccessibilityLabel(isBackButton ? "Back" : nil)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isBackButton { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isBackButton else { return false }
        onPress?()
        return true
    }
}
