import AppKit

/// Routes a text field's delegate callbacks to closures, so cards, chips and forms can share one
/// kind of field without each being its delegate.
final class FieldRelay: NSObject, NSTextFieldDelegate {
    /// The committed text changed. Not called while an input method is composing text.
    var onChange: ((String) -> Void)?
    /// A command from the field editor, such as `insertNewline(_:)` or `moveDown(_:)`. Return
    /// true when handled; false lets the editor do its default.
    var onCommand: ((Selector) -> Bool)?
    /// Editing ended: the field lost focus.
    var onEndEditing: (() -> Void)?

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        return onCommand?(selector) ?? false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onEndEditing?()
    }
}

extension NSView {
    /// Sets the frame only when it differs. Resizing an `NSTextField` while it is being edited
    /// ends its editing and selects all of its text, so a field must not be resized needlessly.
    func setFrameIfChanged(_ frame: CGRect) {
        if self.frame != frame { self.frame = frame }
    }
}

/// What every text field inside the panel shares: no bezel, no background, no focus ring of
/// its own, one scrolling line, and no intrinsic size.
///
/// Without an intrinsic size a text change never asks the window's layout engine for a pass;
/// the glass hosts SwiftUI, which gives the panel one, and a plain field's edit ran it per key.
@MainActor protocol PanelField: NSTextField {
    var relay: FieldRelay { get }
    /// Called when the field becomes first responder.
    var onFocus: (() -> Void)? { get set }
    /// The placeholder's text. AppKit restyles a placeholder when the font changes, so the field
    /// keeps the text and styles it again.
    var placeholderText: String { get set }
    /// The placeholder's colour: the theme's ghost-text colour. The system's tertiary colour
    /// drew as dark as typed text inside a filled field.
    var placeholderColor: NSColor { get set }
}

extension PanelField {
    func configurePanelField() {
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.wraps = false
        cell?.isScrollable = true
        textColor = .labelColor
        allowsWritingTools = false
        delegate = relay
    }

    /// Sets the placeholder in the field's font and the tertiary label colour.
    func setPlaceholder(_ text: String) {
        placeholderText = text
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: placeholderColor])
    }

    /// The height of one line in the field's font, plus the field's own text inset.
    var lineHeight: CGFloat {
        guard let font else { return 0 }
        return ceil(font.ascender - font.descender + font.leading) + 4
    }
}

/// A single-line text field for cards, chips and forms. It uses the panel's tuned field editor.
final class PanelTextField: NSTextField, PanelField {
    let relay = FieldRelay()
    var onFocus: (() -> Void)?
    var placeholderText = ""
    var placeholderColor: NSColor = .tertiaryLabelColor {
        didSet { if !placeholderText.isEmpty { setPlaceholder(placeholderText) } }
    }

    override var font: NSFont? {
        didSet { if !placeholderText.isEmpty { setPlaceholder(placeholderText) } }
    }

    convenience init() {
        self.init(frame: .zero)
        configurePanelField()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// A secure single-line text field. It keeps AppKit's secure field editor: `GlassPanel` hands the
/// shared editor only to plain text fields.
final class PanelSecureTextField: NSSecureTextField, PanelField {
    let relay = FieldRelay()
    var onFocus: (() -> Void)?
    var placeholderText = ""
    var placeholderColor: NSColor = .tertiaryLabelColor {
        didSet { if !placeholderText.isEmpty { setPlaceholder(placeholderText) } }
    }

    override var font: NSFont? {
        didSet { if !placeholderText.isEmpty { setPlaceholder(placeholderText) } }
    }

    convenience init() {
        self.init(frame: .zero)
        configurePanelField()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}
