import AppKit

/// The base of every form control: its value, its change and focus reports, the inset field it
/// sits in, and the keys that move between fields.
///
/// Tab and Return move to the next field, Shift-Tab to the previous one, and Escape asks the form
/// to cancel. `FormView` builds one control per focusable item and keeps it while the item's kind
/// stays the same, so editing never loses the caret to an update.
class FormControlView: NSView {
    /// The user changed the value.
    var onChange: ((FormValue) -> Void)?
    /// The control took (true) or lost (false) keyboard focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Escape was pressed in the control.
    var onEscape: (() -> Void)?
    /// `preferredHeight(width:)` may have changed, as when tags wrap to a new line.
    var onHeightChange: (() -> Void)?

    private(set) var theme: ResolvedTheme?
    private(set) var isFocused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var value: FormValue { .text("") }
    /// Shows a value the host set. Never reports it back through `onChange`.
    func setValue(_ value: FormValue) {}
    /// Takes a new placeholder, option list or label for the same kind of control.
    func update(_ kind: FormItem.Kind) {}
    /// Takes everything an item sets: its kind, and the options some kinds read, such as
    /// placeholder highlighting and tag suggestions.
    func configure(_ item: FormItem) { update(item.kind) }
    /// Selects `range` of the control's text, in UTF-16 offsets, and returns whether it has text.
    /// The control must already have focus.
    func selectText(_ range: NSRange) -> Bool { false }
    /// The view Tab moves into, and the view Tab leaves from.
    var firstKeyView: NSView { self }
    var lastKeyView: NSView { self }
    /// Whether the control sits in an inset field. A checkbox does not.
    var usesWell: Bool { true }
    /// The height the control needs at `width`, or nil for its kind's default.
    func preferredHeight(width: CGFloat) -> CGFloat? { nil }
    /// Where a one-line control draws its text, in its own coordinates, for inspection.
    var textFrame: CGRect? { nil }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        let form = theme.theme.form
        layer?.cornerRadius = CGFloat(form.fieldCornerRadius)
        layer?.backgroundColor = usesWell ? theme.form.fieldFill : nil
        showFocus(isFocused)
        needsLayout = true
    }

    /// Records a focus change, shows it and reports it.
    func reportFocus(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        showFocus(focused)
        onFocusChange?(focused)
    }

    /// Draws the focus ring around the field. A control without a field overrides this.
    func showFocus(_ focused: Bool) {
        guard let theme, usesWell else { return }
        layer?.borderWidth = focused ? CGFloat(theme.theme.form.focusRingWidth) : 0
        layer?.borderColor = theme.form.focusRing
    }

    /// The field-editor commands every text control shares: Tab and Return move on, Shift-Tab
    /// moves back, Escape cancels. Returns false for anything else.
    func handleTextCommand(_ selector: Selector, in field: NSView) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            window?.selectKeyView(following: lastKeyView)
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectKeyView(preceding: firstKeyView)
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
        default:
            return false
        }
        return true
    }

    /// The same keys for controls that are their own key view. Returns false for other keys.
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        switch chord.key {
        case KeyChord.Key.tab:
            if chord.modifiers.contains(.shift) {
                window?.selectKeyView(preceding: firstKeyView)
            } else {
                window?.selectKeyView(following: lastKeyView)
            }
        case KeyChord.Key.escape:
            onEscape?()
        default:
            return false
        }
        return true
    }
}

/// A single-line text field, plain or secure.
final class TextFormControl: FormControlView {
    private let field: any PanelField

    /// Colours `{...}` placeholders. Never on for a secure field.
    private var highlightsPlaceholders = false
    /// The field editor that carries this field's placeholder colours while it edits.
    private weak var highlightedEditor: NSTextView?

    init(secure: Bool) {
        field = secure ? PanelSecureTextField() : PanelTextField()
        super.init(frame: .zero)
        addSubview(field)
        field.relay.onChange = { [weak self] text in
            self?.highlightWhileEditing()
            self?.onChange?(.text(text))
        }
        field.relay.onCommand = { [weak self] selector in
            guard let self else { return false }
            return handleTextCommand(selector, in: field)
        }
        field.relay.onEndEditing = { [weak self] in
            self?.endHighlighting()
            self?.reportFocus(false)
        }
        field.onFocus = { [weak self] in
            self?.highlightWhileEditing()
            self?.reportFocus(true)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var value: FormValue { .text(field.stringValue) }
    override var firstKeyView: NSView { field }
    override var lastKeyView: NSView { field }
    override var textFrame: CGRect? { field.oneLineTextFrame.map { field.convert($0, to: self) } }

    override func setValue(_ value: FormValue) {
        guard case .text(let text) = value, text != field.stringValue else { return }
        field.stringValue = text
        highlightResting()
        highlightWhileEditing()
    }

    override func update(_ kind: FormItem.Kind) {
        switch kind {
        case .text(let placeholder), .secure(let placeholder): field.setPlaceholder(placeholder)
        default: break
        }
    }

    override func configure(_ item: FormItem) {
        super.configure(item)
        let highlights = item.highlightsPlaceholders && !(field is NSSecureTextField)
        guard highlights != highlightsPlaceholders else { return }
        highlightsPlaceholders = highlights
        highlightResting()
        highlightWhileEditing()
    }

    override func apply(_ theme: ResolvedTheme) {
        field.font = theme.form.controlFont
        field.placeholderColor = NSColor(cgColor: theme.ghostText) ?? .tertiaryLabelColor
        super.apply(theme)
        highlightResting()
        highlightWhileEditing()
    }

    override func selectText(_ range: NSRange) -> Bool {
        guard !(field is NSSecureTextField), let editor = field.currentEditor() else { return false }
        editor.selectedRange = PlaceholderHighlighter.clamped(range, length: (editor.string as NSString).length)
        return true
    }

    // MARK: Placeholders

    /// Colours the placeholders of the text shown while the field does not edit.
    private func highlightResting() {
        guard let theme, field.currentEditor() == nil, !(field is NSSecureTextField) else { return }
        let text = field.stringValue
        guard highlightsPlaceholders, !PlaceholderHighlighter.ranges(in: text).isEmpty else {
            if field.attributedStringValue.length > 0 { field.stringValue = text }
            return
        }
        field.attributedStringValue = PlaceholderHighlighter.attributed(
            text, font: theme.form.controlFont, color: NSColor.labelColor, theme: theme)
    }

    /// Colours the placeholders in the field editor while the field edits. The colours are
    /// temporary attributes of the shared editor's layout manager, so they never reach the value.
    private func highlightWhileEditing() {
        guard highlightsPlaceholders, let theme, let editor = field.currentEditor() as? NSTextView else { return }
        highlightedEditor = editor
        PlaceholderHighlighter.apply(to: editor, theme: theme)
    }

    /// Takes the placeholder colours off the shared editor before another field uses it.
    private func endHighlighting() {
        if let editor = highlightedEditor { PlaceholderHighlighter.clear(editor) }
        highlightedEditor = nil
        highlightResting()
    }

    override func layout() {
        super.layout()
        guard let theme else { return }
        let padding = CGFloat(theme.theme.form.fieldPadding)
        let height = field.lineHeight
        field.setFrameIfChanged(
            CGRect(
                x: padding - 2, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - padding * 2 + 4,
                height: height))
    }
}

/// Several lines of text, scrolling inside its field. Tab leaves the field instead of typing a
/// tab; Return types a new line.
final class MultilineFormControl: FormControlView {
    private let scrollView = NSScrollView()
    let textView = FormTextView(usingTextLayoutManager: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textColor = .labelColor
        scrollView.documentView = textView
        addSubview(scrollView)
        textView.onFocusChange = { [weak self] focused in self?.reportFocus(focused) }
        textView.onTextChange = { [weak self] text in self?.onChange?(.text(text)) }
        textView.onCommand = { [weak self] selector in
            guard let self else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return false
            default: return handleTextCommand(selector, in: textView)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override var value: FormValue { .text(textView.string) }
    override var firstKeyView: NSView { textView }
    override var lastKeyView: NSView { textView }

    override func setValue(_ value: FormValue) {
        if case .text(let text) = value, text != textView.string {
            textView.string = text
            textView.refreshPlaceholders()
        }
    }

    override func update(_ kind: FormItem.Kind) {
        if case .multiline(let placeholder) = kind { textView.placeholder = placeholder }
    }

    override func configure(_ item: FormItem) {
        super.configure(item)
        guard item.highlightsPlaceholders != textView.highlightsPlaceholders else { return }
        textView.highlightsPlaceholders = item.highlightsPlaceholders
        textView.refreshPlaceholders()
    }

    override func selectText(_ range: NSRange) -> Bool {
        textView.setSelectedRange(PlaceholderHighlighter.clamped(range, length: (textView.string as NSString).length))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    override func apply(_ theme: ResolvedTheme) {
        textView.font = theme.form.controlFont
        textView.insertionPointColor = NSColor(cgColor: theme.accent) ?? .controlAccentColor
        textView.theme = theme
        let padding = CGFloat(theme.theme.form.fieldPadding)
        textView.textContainerInset = NSSize(width: padding - 5, height: padding / 2 + 1)
        super.apply(theme)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = scrollView.contentSize.width
    }
}

/// The text view inside a multiline field: it reports focus, text changes and editing commands,
/// and draws its placeholder while empty.
final class FormTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onCommand: ((Selector) -> Bool)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    /// Colours `{...}` placeholders with temporary attributes, so they never reach the value.
    var highlightsPlaceholders = false
    var theme: ResolvedTheme? {
        didSet { refreshPlaceholders() }
    }

    func refreshPlaceholders() {
        if highlightsPlaceholders, let theme {
            PlaceholderHighlighter.apply(to: self, theme: theme)
        } else {
            PlaceholderHighlighter.clear(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        if highlightsPlaceholders { refreshPlaceholders() }
        if !hasMarkedText() { onTextChange?(string) }
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        if !hasMarkedText(), onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let inset = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: origin.x + inset, y: origin.y),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
    }
}
