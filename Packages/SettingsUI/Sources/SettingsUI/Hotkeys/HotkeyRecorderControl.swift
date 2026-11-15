import AppKit
import Kit
import SwiftUI

/// The focusable part of the hotkey recorder: a field that records while it has keyboard focus.
///
/// It reads only the key events its own window sends it, through `keyDown`,
/// `performKeyEquivalent` and `flagsChanged`. It installs no event monitor and registers nothing
/// with the system.
final class HotkeyRecorderField: NSView {
    var model: HotkeyRecorderModel? {
        didSet { refresh() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
    }

    override func becomeFirstResponder() -> Bool {
        model?.beginRecording()
        refresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        model?.endRecording()
        refresh()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !record(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return record(event) || super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        model?.modifiersChanged(Self.modifiers(event))
        refresh()
        super.flagsChanged(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    /// Hands one key press to the model. Returns whether it was used.
    private func record(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let model else { return false }
        let used = model.handle(key: Key(code: event.keyCode), modifiers: Self.modifiers(event))
        if used && !model.isRecording { window?.makeFirstResponder(nil) }
        refresh()
        return used
    }

    private static func modifiers(_ event: NSEvent) -> KeyModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyModifiers(rawValue: UInt(flags.rawValue)).intersection(HotkeyRecorderModel.hotkeyModifiers)
    }

    func refresh() {
        needsDisplay = true
        guard let model else { return }
        setAccessibilityLabel(model.target.title)
        setAccessibilityValue(model.isRecording ? "Recording" : (model.combo?.displayString ?? "None"))
        setAccessibilityHelp("Press to record a shortcut. Delete clears it, Escape stops recording.")
    }

    override func draw(_ dirtyRect: NSRect) {
        let recording = model?.isRecording ?? false
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let text = model?.displayText ?? ""
        let hasValue = !recording && model?.combo != nil
        let font = hasValue ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.systemFont(ofSize: 12)
        let color: NSColor = hasValue ? .labelColor : .secondaryLabelColor
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The recorder field in SwiftUI.
struct HotkeyRecorderRepresentable: NSViewRepresentable {
    let model: HotkeyRecorderModel

    func makeNSView(context: Context) -> HotkeyRecorderField {
        let field = HotkeyRecorderField()
        field.model = model
        return field
    }

    func updateNSView(_ field: HotkeyRecorderField, context: Context) {
        if field.model !== model { field.model = model }
        // Reading the model here makes SwiftUI call this again when its text changes.
        _ = model.displayText
        field.refresh()
    }
}

/// A hotkey recorder: the field, a clear button, and the conflict review under it.
struct HotkeyRecorder: View {
    let model: HotkeyRecorderModel
    /// False leaves out the note that a macOS shortcut holds the stored combination, for a host
    /// that shows its own notice about it.
    var showsHeldNote = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                HotkeyRecorderRepresentable(model: model)
                    .frame(width: 150, height: 24)
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.combo == nil)
                .opacity(model.combo == nil ? 0 : 1)
                .accessibilityLabel("Clear \(model.target.title)")
                .help("Clear")
            }
            // Forms line rows up by text baseline; the field has none SwiftUI can see.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            if let note = model.note, showsHeldNote || !isHeld {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if case .review = model.state {
                        Button("Cancel") { model.dismiss() }
                        Button("Replace") { model.confirmReplace() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("OK") { model.dismiss() }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var isWarning: Bool {
        switch model.state {
        case .review, .held: false
        default: true
        }
    }

    private var isHeld: Bool {
        if case .held = model.state { return true }
        return false
    }
}
