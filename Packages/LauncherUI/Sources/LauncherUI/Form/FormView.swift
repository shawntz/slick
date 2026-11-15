import AppKit

/// A form inside the panel: a right-aligned label column, one control per field in glass-inset
/// fields, and error or help text under any field that has one.
///
/// Tab and Shift-Tab move through the fields in order and wrap; Return moves on from a one-line
/// field; Command-Return submits; Escape cancels. The form scrolls when it is taller than the
/// content area and keeps the focused field in view. Fields keep their controls, and so their
/// caret and selection, across `apply(_:)` while their kind stays the same.
public final class FormView: NSView, LauncherContentView, PanelKeyHandling {
    /// A field's value changed: its id and new value.
    public var onChange: ((String, FormValue) -> Void)?
    /// A file field's choose button was pressed: its id. The host shows a picker and sets the
    /// field's value with `apply(_:)`.
    public var onChooseFile: ((String) -> Void)?
    /// Command-Return was pressed. When nil, the chord goes on to the host's key handling.
    public var onSubmit: (() -> Void)?
    /// Escape was pressed in a field.
    public var onCancel: (() -> Void)?
    public var contentHeightDidChange: (() -> Void)?
    /// Unused: a form shows no selection.
    public weak var selectionLens: SelectionLens?

    public private(set) var content: FormContent = .empty
    /// The field with keyboard focus.
    public private(set) var focusedID: String?

    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private var rows: [String: FormRowViews] = [:]
    private(set) var layoutModel = FormLayout(items: [], controlHeights: [], metrics: Theme.standard.form, width: 0)
    private var theme: ResolvedTheme?
    /// The values the host set last, so an update changes a field only when the host's value did.
    private var appliedValues: [String: FormValue] = [:]

    override public init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        min(limit, CGFloat(layoutModel.contentHeight))
    }

    /// Every field's current value, by id.
    public var values: [String: FormValue] {
        rows.compactMapValues { $0.control?.value }
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        for row in rows.values { row.apply(theme) }
        relayout()
    }

    /// Shows new fields, labels, values and messages. A field the host gives the same value as
    /// last time keeps what the user typed since.
    public func apply(_ newContent: FormContent) {
        guard newContent != content else { return }
        content = newContent
        let ids = Set(newContent.items.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.remove()
            rows[id] = nil
            appliedValues[id] = nil
        }
        for item in newContent.items {
            if let row = rows[item.id], row.kind.usesSameControl(as: item.kind) {
                row.update(item)
            } else {
                rows[item.id]?.remove()
                let row = makeRow(item)
                rows[item.id] = row
                appliedValues[item.id] = nil
            }
            if appliedValues[item.id] != item.value {
                rows[item.id]?.control?.setValue(item.value)
                appliedValues[item.id] = item.value
            }
        }
        linkKeyViews()
        relayout()
    }

    /// Moves keyboard focus to the field `id`, or to the first field when nil.
    public func focus(_ id: String? = nil) {
        let target = id ?? content.items.first(where: \.isFocusable)?.id
        guard let target, let control = rows[target]?.control else { return }
        // Size the fields first: resizing a field that is being edited would end its editing.
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(control.firstKeyView)
    }

    /// Focuses the text field `id` and selects `range` of its text, in UTF-16 offsets, such as a
    /// placeholder the user should fill in next. The range is clamped to the text. It works for
    /// one-line and multiline text fields, file paths and a tag field's input. For other kinds and
    /// unknown ids it returns false and leaves focus where it was.
    @discardableResult
    public func selectText(in id: String, range: NSRange) -> Bool {
        guard let item = content.items.first(where: { $0.id == id }), let control = rows[id]?.control else {
            return false
        }
        switch item.kind {
        case .text, .multiline, .filePath, .tags: break
        default: return false
        }
        if window?.firstResponder !== control.firstKeyView, control.firstKeyView.window != nil {
            focus(id)
        }
        return control.selectText(range)
    }

    /// The control showing field `id`, for tests.
    func control(for id: String) -> FormControlView? { rows[id]?.control }

    /// The views of field `id`, for inspection.
    func rowViews(for id: String) -> FormRowViews? { rows[id] }

    func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let onSubmit, let chord = KeyChord(event: event), chord.key == KeyChord.Key.returnKey,
            chord.modifiers == .command
        else { return false }
        onSubmit()
        return true
    }

    // MARK: Rows

    private func makeRow(_ item: FormItem) -> FormRowViews {
        let row = FormRowViews(item: item, in: document)
        if let control = row.control {
            let id = item.id
            control.onChange = { [weak self] value in self?.onChange?(id, value) }
            control.onEscape = { [weak self] in self?.onCancel?() }
            control.onHeightChange = { [weak self] in self?.relayout() }
            control.onFocusChange = { [weak self] focused in self?.focusChanged(id, focused: focused) }
            if let file = control as? FilePathFormControl { file.onChoose = { [weak self] in self?.onChooseFile?(id) } }
        }
        if let theme { row.apply(theme) }
        return row
    }

    private func focusChanged(_ id: String, focused: Bool) {
        if focused {
            focusedID = id
            if let index = content.items.firstIndex(where: { $0.id == id }), index < layoutModel.rows.count {
                document.scrollToVisible(
                    layoutModel.rows[index].frame.insetBy(dx: 0, dy: -CGFloat(theme?.theme.form.rowSpacing ?? 0)))
            }
        } else if focusedID == id {
            focusedID = nil
        }
    }

    /// Tab goes through the fields in order and wraps from the last to the first.
    private func linkKeyViews() {
        let controls = content.items.compactMap { rows[$0.id]?.control }
        for (index, control) in controls.enumerated() {
            control.lastKeyView.nextKeyView = controls[(index + 1) % controls.count].firstKeyView
        }
    }

    // MARK: Layout

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        guard let theme else { return }
        let metrics = theme.theme.form
        let width = bounds.width
        let controlWidth = max(0, width - metrics.horizontalInset * 2 - metrics.labelWidth - metrics.labelGap)
        let heights = content.items.map { item -> Double in
            let row = rows[item.id]
            if let height = row?.descriptionHeight(width: CGFloat(controlWidth)) { return Double(height) }
            if let height = row?.control?.preferredHeight(width: CGFloat(controlWidth)) { return Double(height) }
            return FormLayout.defaultControlHeight(item.kind, metrics: metrics)
        }
        let old = layoutModel.contentHeight
        layoutModel = FormLayout(items: content.items, controlHeights: heights, metrics: metrics, width: Double(width))
        for (item, frames) in zip(content.items, layoutModel.rows) { rows[item.id]?.place(frames, theme: theme) }
        let visible = preferredContentHeight(limit: bounds.height)
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: visible)
        document.frame = CGRect(
            x: 0, y: 0, width: scrollView.contentSize.width, height: CGFloat(layoutModel.contentHeight))
        if old != layoutModel.contentHeight { contentHeightDidChange?() }
    }
}

/// The views of one form row: its label, its control or static content, and its message.
@MainActor
final class FormRowViews {
    private(set) var kind: FormItem.Kind
    let control: FormControlView?
    private let label = StaticLabel()
    private let message = StaticLabel()
    private var description: NSTextField?
    private var separator: NSView?
    private var hasError = false

    init(item: FormItem, in document: NSView) {
        kind = item.kind
        switch item.kind {
        case .text: control = TextFormControl(secure: false)
        case .secure: control = TextFormControl(secure: true)
        case .multiline: control = MultilineFormControl()
        case .dropdown: control = DropdownFormControl()
        case .checkbox: control = CheckboxFormControl()
        case .date: control = DateFormControl()
        case .filePath: control = FilePathFormControl()
        case .tags: control = TagFormControl()
        case .hotkey: control = HotkeyRecorderField()
        case .application: control = DropdownFormControl()
        case .description, .separator: control = nil
        }
        label.alignment = .right
        document.addSubview(label)
        document.addSubview(message)
        if let control { document.addSubview(control) }
        if case .description = item.kind {
            let text = NSTextField(wrappingLabelWithString: "")
            text.textColor = .secondaryLabelColor
            text.isSelectable = false
            description = text
            document.addSubview(text)
        }
        if case .separator = item.kind {
            let line = NSView()
            line.wantsLayer = true
            separator = line
            document.addSubview(line)
        }
        update(item)
    }

    func update(_ item: FormItem) {
        kind = item.kind
        label.stringValue = item.label
        control?.configure(item)
        control?.setAccessibilityLabel(item.label.isEmpty ? nil : item.label)
        if case .description(let text) = item.kind { description?.stringValue = text }
        message.stringValue = item.message ?? ""
        message.isHidden = item.message == nil
        hasError = item.error != nil
        if let theme = control?.theme { styleMessage(theme) }
    }

    func apply(_ theme: ResolvedTheme) {
        label.font = theme.form.labelFont
        label.textColor = NSColor(cgColor: theme.subtitle)
        message.font = theme.form.messageFont
        description?.font = theme.form.controlFont
        separator?.layer?.backgroundColor = theme.hairline
        control?.apply(theme)
        styleMessage(theme)
    }

    private func styleMessage(_ theme: ResolvedTheme) {
        message.textColor = hasError ? theme.form.error : NSColor(cgColor: theme.subtitle)
    }

    var labelSuperview: NSView? { label.superview }
    /// Where the label and the message draw their text, in the form's document coordinates.
    var labelTextFrame: CGRect? { label.oneLineTextFrame.map { label.convert($0, to: label.superview) } }
    var messageTextFrame: CGRect? {
        message.isHidden ? nil : message.oneLineTextFrame.map { message.convert($0, to: message.superview) }
    }

    func descriptionHeight(width: CGFloat) -> CGFloat? {
        guard let description else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(description.cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    func place(_ frames: FormLayout.Row, theme: ResolvedTheme) {
        let lineHeight = label.lineHeight
        label.frame = CGRect(
            x: frames.label.minX, y: frames.label.minY + ((frames.label.height - lineHeight) / 2).rounded(),
            width: frames.label.width, height: lineHeight)
        control?.frame = frames.control
        description?.frame = frames.control
        if let separator {
            let hairline = 1 / (separator.window?.backingScaleFactor ?? 2)
            separator.frame = CGRect(
                x: frames.control.minX, y: (frames.control.midY - hairline / 2).rounded(), width: frames.control.width,
                height: hairline)
        }
        if let frame = frames.message { message.frame = frame }
    }

    func remove() {
        for view in [label, message, control, description, separator].compactMap({ $0 as NSView? }) {
            view.removeFromSuperview()
        }
    }
}
