import AppKit

/// Records a shortcut: while it has focus, the next chord with Command, Control or Option becomes
/// its value and shows as keycaps. Delete clears it; Tab and Escape behave as in any field.
///
/// It only reads key events sent to the panel. It registers nothing with the system; turning the
/// recorded chord into a global hotkey is the host's job. It sees Command chords before the host
/// does, through `PanelKeyHandling`.
final class HotkeyRecorderField: FormControlView, PanelKeyHandling {
    private(set) var chord: KeyChord?
    private var placeholder = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var value: FormValue { .hotkey(chord) }

    override func setValue(_ value: FormValue) {
        guard case .hotkey(let chord) = value, chord != self.chord else { return }
        self.chord = chord
        changed(report: false)
    }

    override func update(_ kind: FormItem.Kind) {
        guard case .hotkey(let placeholder) = kind else { return }
        self.placeholder = placeholder
        setAccessibilityLabel(placeholder)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        reportFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        reportFocus(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if !record(event) { super.keyDown(with: event) }
    }

    func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool {
        window?.firstResponder === self && record(event)
    }

    /// Handles one key press while focused. Returns whether it was used.
    func record(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let pressed = KeyChord(event: event) else { return false }
        let modifiers = pressed.modifiers
        if modifiers.isDisjoint(with: [.command, .control, .option]) {
            if pressed.key == KeyChord.Key.delete {
                chord = nil
                changed(report: true)
                return true
            }
            // Tab, Shift-Tab and Escape move on or cancel, as in every field.
            return handleNavigationKey(event)
        }
        chord = pressed
        changed(report: true)
        return true
    }

    private func changed(report: Bool) {
        needsDisplay = true
        setAccessibilityValue(chord.map { $0.keycaps.joined() })
        if report { onChange?(.hotkey(chord)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(theme.theme.form.fieldPadding)
        if let chord {
            let keys = chord.keycaps
            let width = KeycapRenderer.width(keys, theme: theme)
            KeycapRenderer.draw(
                keys, right: padding + width, top: 0, height: bounds.height, theme: theme, context: context,
                scale: scale)
            return
        }
        let font = theme.form.controlFont as CTFont
        let line = CTLineCreateWithAttributedString(
            RowTypesetter.attributed(placeholder, font: font, color: theme.ghostText))
        let baseline = RowTypesetter.snap(RowTypesetter.baseline(centering: font, in: bounds.height), scale)
        RowRenderer.draw(.init(line: line, origin: CGPoint(x: padding, y: baseline)), context)
    }
}

extension KeyChord {
    /// The chord as keycap labels, modifiers first in the system's order: `["⌥", "⌘", "K"]`.
    public var keycaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        let named: [String: String] = [
            Key.returnKey: "↩", Key.escape: "⎋", Key.tab: "⇥", Key.delete: "⌫", Key.up: "↑", Key.down: "↓",
            Key.left: "←", Key.right: "→", Key.space: "Space",
        ]
        caps.append(named[key] ?? key.uppercased())
        return caps
    }
}
