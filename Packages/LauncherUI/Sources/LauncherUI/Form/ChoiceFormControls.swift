import AppKit
import CoreText

/// A dropdown: the chosen option's icon, title and a chevron. Clicking it, or pressing Space,
/// Return, Up or Down while it has focus, opens its options as a menu inside the panel.
///
/// It also draws the application picker: the options are apps with their icons, the field shows
/// a placeholder until one is chosen, and an id that is not among the options shows as typed.
final class DropdownFormControl: FormControlView {
    private(set) var options: [MenuOption] = []
    private(set) var selectedID: String?
    /// Shown in the ghost colour while nothing is chosen.
    private(set) var placeholder = ""
    private var symbol: CGImage?
    /// The chosen option's icon, rendered for drawing.
    private var iconImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var value: FormValue { .option(selectedID) }

    override func setValue(_ value: FormValue) {
        guard case .option(let id) = value, id != selectedID else { return }
        selectedID = id
        renderIcon()
        needsDisplay = true
        setAccessibilityValue(selectedTitle)
    }

    override func update(_ kind: FormItem.Kind) {
        let options: [MenuOption]
        switch kind {
        case .dropdown(let choices): options = choices
        case .application(let placeholder, let apps):
            options = apps
            if placeholder != self.placeholder {
                self.placeholder = placeholder
                needsDisplay = true
            }
        default: return
        }
        guard options != self.options else { return }
        self.options = options
        renderIcon()
        needsDisplay = true
        setAccessibilityValue(selectedTitle)
    }

    /// The chosen option's title, the chosen id when it is not an option, or empty.
    var selectedTitle: String {
        guard let selectedID else { return "" }
        return options.first { $0.id == selectedID }?.title ?? selectedID
    }

    override func apply(_ theme: ResolvedTheme) {
        symbol = SymbolRenderer.image(
            "chevron.up.chevron.down", pointSize: CGFloat(theme.theme.chips.chevronSize) + 2, color: theme.subtitle,
            scale: window?.backingScaleFactor ?? 2)
        super.apply(theme)
        renderIcon()
        needsDisplay = true
    }

    private func renderIcon() {
        iconImage = nil
        guard let theme, let icon = options.first(where: { $0.id == selectedID })?.icon else { return }
        switch icon {
        case .image(let image): iconImage = image
        case .symbol(let name):
            iconImage = SymbolRenderer.image(
                name, pointSize: CGFloat(theme.theme.list.accessoryIconSize), color: theme.title,
                scale: window?.backingScaleFactor ?? 2)
        }
    }

    override func becomeFirstResponder() -> Bool {
        reportFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        reportFocus(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleNavigationKey(event) { return }
        guard let chord = KeyChord(event: event) else { return }
        switch chord.key {
        case KeyChord.Key.space, KeyChord.Key.returnKey, KeyChord.Key.up, KeyChord.Key.down: openMenu()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        openMenu()
    }

    /// Shows the options under the field, inside the panel.
    func openMenu() {
        guard let surface = (window as? GlassPanel)?.surface, !options.isEmpty else { return }
        let menu = DropdownMenuView(
            options: options, selectedID: selectedID,
            placement: .below(convert(bounds, to: surface.overlaySpace), trailingAligned: false))
        menu.onChoose = { [weak self] option in
            guard let self, option.id != selectedID else { return }
            selectedID = option.id
            renderIcon()
            needsDisplay = true
            setAccessibilityValue(selectedTitle)
            onChange?(.option(option.id))
        }
        surface.present(menu)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let form = theme.theme.form
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(form.fieldPadding)
        let font = theme.form.controlFont as CTFont
        var right = bounds.width - padding
        if let symbol {
            let size = CGFloat(symbol.width) / scale
            let frame = CGRect(
                x: right - size, y: RowTypesetter.snap((bounds.height - size) / 2, scale), width: size, height: size)
            RowRenderer.drawImage(symbol, in: frame, context: context)
            right = frame.minX - padding
        }
        var left = padding
        if let iconImage {
            let size = CGFloat(theme.theme.list.accessoryIconSize)
            let frame = CGRect(
                x: left, y: RowTypesetter.snap((bounds.height - size) / 2, scale), width: size, height: size)
            RowRenderer.drawImage(iconImage, in: frame, context: context)
            left = frame.maxX + CGFloat(theme.theme.list.accessorySpacing)
        }
        let showsPlaceholder = selectedID == nil && !placeholder.isEmpty
        let color = showsPlaceholder ? theme.ghostText : theme.title
        let line = RowTypesetter.truncate(
            CTLineCreateWithAttributedString(
                RowTypesetter.attributed(showsPlaceholder ? placeholder : selectedTitle, font: font, color: color)),
            to: max(0, right - left), font: font, color: color)
        let baseline = RowTypesetter.snap(RowTypesetter.baseline(centering: font, in: bounds.height), scale)
        RowRenderer.draw(.init(line: line, origin: CGPoint(x: left, y: baseline)), context)
    }
}

/// A checkbox and its label. Click it, or press Space while it has focus, to toggle it.
final class CheckboxFormControl: FormControlView {
    private(set) var isOn = false
    private let label = FixedLabel()
    private let box = NSView()
    private var checkmark = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.addSublayer(checkmark)
        label.textColor = .labelColor
        addSubview(box)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var usesWell: Bool { false }
    override var value: FormValue { .bool(isOn) }

    override func setValue(_ value: FormValue) {
        guard case .bool(let on) = value, on != isOn else { return }
        isOn = on
        restyle()
    }

    override func update(_ kind: FormItem.Kind) {
        guard case .checkbox(let text) = kind else { return }
        label.stringValue = text
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func apply(_ theme: ResolvedTheme) {
        label.font = theme.form.controlFont
        let form = theme.theme.form
        box.layer?.cornerRadius = CGFloat(form.checkboxCornerRadius)
        let size = CGFloat(form.checkboxSize)
        let scale = window?.backingScaleFactor ?? 2
        checkmark.contents = SymbolRenderer.image(
            "checkmark", pointSize: size, weight: .bold, color: theme.form.onProminent, scale: scale)
        checkmark.contentsScale = scale
        super.apply(theme)
        restyle()
    }

    private func restyle() {
        guard let theme else { return }
        box.layer?.backgroundColor = isOn ? theme.form.prominent : theme.form.fieldFill
        checkmark.isHidden = !isOn
        setAccessibilityValue(isOn)
    }

    override func showFocus(_ focused: Bool) {
        guard let theme else { return }
        box.layer?.borderWidth = focused ? CGFloat(theme.theme.form.focusRingWidth) : 0
        box.layer?.borderColor = theme.form.focusRing
    }

    override func becomeFirstResponder() -> Bool {
        reportFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        reportFocus(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleNavigationKey(event) { return }
        if KeyChord(event: event)?.key == KeyChord.Key.space { toggle() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    func toggle() {
        isOn.toggle()
        restyle()
        onChange?(.bool(isOn))
    }

    /// The width the box and the label need on one line.
    var fittingWidth: CGFloat {
        guard let theme else { return 0 }
        let form = theme.theme.form
        return ceil(CGFloat(form.checkboxSize) + CGFloat(form.fieldPadding) + label.textWidth)
    }

    /// Where the label draws its text, in the control's coordinates, for inspection.
    var labelTextFrame: CGRect? { label.oneLineTextFrame.map { label.convert($0, to: self) } }

    override func layout() {
        super.layout()
        guard let theme else { return }
        let form = theme.theme.form
        let size = CGFloat(form.checkboxSize)
        box.frame = CGRect(x: 0, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        checkmark.frame = box.bounds
        CATransaction.commit()
        let height = label.lineHeight
        let x = size + CGFloat(form.fieldPadding)
        label.frame = CGRect(
            x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - x), height: height)
    }
}

/// A date, and optionally a time, typed or stepped with the arrow keys. A text-style picker, so
/// no calendar popover opens outside the panel.
final class DateFormControl: FormControlView {
    private let picker = FormDatePicker()
    private var hasValue = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.datePickerStyle = .textField
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.textColor = .labelColor
        picker.dateValue = Date()
        picker.target = self
        picker.action = #selector(dateChanged)
        picker.onFocusChange = { [weak self] focused in self?.reportFocus(focused) }
        picker.onKey = { [weak self] event in self?.handleNavigationKey(event) ?? false }
        addSubview(picker)
    }

    required init?(coder: NSCoder) { nil }

    override var value: FormValue { .date(hasValue ? picker.dateValue : nil) }
    override var firstKeyView: NSView { picker }
    override var lastKeyView: NSView { picker }

    override func setValue(_ value: FormValue) {
        guard case .date(let date) = value else { return }
        hasValue = date != nil
        if let date, date != picker.dateValue { picker.dateValue = date }
    }

    override func update(_ kind: FormItem.Kind) {
        guard case .date(let includesTime) = kind else { return }
        picker.datePickerElements = includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
    }

    override func apply(_ theme: ResolvedTheme) {
        picker.font = theme.form.controlFont
        super.apply(theme)
    }

    @objc private func dateChanged() {
        hasValue = true
        onChange?(.date(picker.dateValue))
    }

    override func layout() {
        super.layout()
        guard let theme else { return }
        let padding = CGFloat(theme.theme.form.fieldPadding)
        let height = ceil(picker.fittingSize.height)
        picker.frame = CGRect(
            x: padding - 3, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - padding * 2,
            height: height)
    }
}

/// The date picker inside a date field: it reports focus and lets Tab and Escape through.
final class FormDatePicker: NSDatePicker {
    var onFocusChange: ((Bool) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

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

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
