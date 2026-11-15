import AppKit

/// A file path the user can type, and a button that asks the host to choose one. LauncherUI opens
/// no dialog itself: an open panel is a second key window, which the glass rules forbid while the
/// launcher shows.
final class FilePathFormControl: FormControlView {
    /// The choose button was pressed.
    var onChoose: (() -> Void)?

    private let field = PanelTextField()
    private let button = CardButton(title: "", key: "", role: .plain)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(field)
        addSubview(button)
        field.relay.onChange = { [weak self] text in self?.onChange?(.text(text)) }
        field.relay.onCommand = { [weak self] selector in
            guard let self else { return false }
            return handleTextCommand(selector, in: field)
        }
        field.relay.onEndEditing = { [weak self] in self?.reportFocus(false) }
        field.onFocus = { [weak self] in self?.reportFocus(true) }
        button.onPress = { [weak self] in self?.onChoose?() }
    }

    required init?(coder: NSCoder) { nil }

    override var value: FormValue { .text(field.stringValue) }
    override var firstKeyView: NSView { field }
    override var lastKeyView: NSView { field }

    override func setValue(_ value: FormValue) {
        if case .text(let text) = value, text != field.stringValue { field.stringValue = text }
    }

    override func selectText(_ range: NSRange) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        editor.selectedRange = PlaceholderHighlighter.clamped(range, length: (editor.string as NSString).length)
        return true
    }

    override func update(_ kind: FormItem.Kind) {
        guard case .filePath(let placeholder, let buttonTitle) = kind else { return }
        field.setPlaceholder(placeholder)
        button.title = buttonTitle
        button.setAccessibilityLabel(buttonTitle)
        needsLayout = true
    }

    override func apply(_ theme: ResolvedTheme) {
        field.font = theme.form.controlFont
        field.placeholderColor = NSColor(cgColor: theme.ghostText) ?? .tertiaryLabelColor
        button.apply(theme)
        super.apply(theme)
    }

    override func layout() {
        super.layout()
        guard let theme else { return }
        let form = theme.theme.form
        let inset = CGFloat(form.focusRingWidth) * 2
        let buttonWidth = button.fittingWidth
        button.frame = CGRect(
            x: bounds.width - inset - buttonWidth, y: inset, width: buttonWidth, height: bounds.height - inset * 2)
        let padding = CGFloat(form.fieldPadding)
        let height = field.lineHeight
        field.setFrameIfChanged(
            CGRect(
                x: padding - 2, y: ((bounds.height - height) / 2).rounded(),
                width: max(0, button.frame.minX - padding * 2 + 4), height: height))
    }
}
