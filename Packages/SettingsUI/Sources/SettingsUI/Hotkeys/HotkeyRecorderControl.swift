import AppKit
import Kit
import SwiftUI

/// The focusable part of the hotkey recorder: a field that records after a click or a press.
///
/// Recording is the model's state. Keyboard focus only routes keys to the field, and focus alone
/// never starts a recording: not when the window opens, and not when Tab reaches the field. A click
/// starts a recording when none runs and stops the one that runs. The click that brings the window
/// forward counts too. A double-click starts one recording: its second click doesn't stop what its
/// first click started, and a quick click after a recording ended starts the next one. A
/// Command-click in a window that isn't key starts nothing, since it leaves the window in the
/// background. With the field focused, Space or Return starts a recording. A window's default
/// button takes Return first, as onboarding's Continue does while no recording runs. The
/// accessibility press starts a recording only in the key window, since it doesn't bring the window
/// forward as a click does. Tab reaches the field only while the Mac's keyboard navigation is on,
/// as it reaches a button.
///
/// Any key but a modifier or Tab ends a recording, by the model's rules, and so does the field
/// losing focus, its window losing key status, a click anywhere else in a ``SettingsWindow`` or the
/// field leaving its window. After a recording that a click started, the field gives up focus. After
/// one the keyboard started, it keeps focus, so Tab goes on from the field.
///
/// It reads only the key events its own window sends it, through `keyDown`,
/// `performKeyEquivalent` and `flagsChanged`, its own window's notice that it stopped being key,
/// and the clicks its own window passes it. It installs no event monitor and registers nothing with
/// the system.
final class HotkeyRecorderField: NSView {
    /// What started the recording that runs.
    private enum Start {
        case click
        case keyboard
    }

    var model: HotkeyRecorderModel? {
        didSet {
            if oldValue !== model, start != nil {
                start = nil
                oldValue?.endRecording()
            }
            refresh()
        }
    }

    /// Whether the Mac's keyboard navigation is on, which lets Tab reach the field. A test replaces
    /// it, so it does not depend on this Mac's setting.
    var keyboardNavigation: () -> Bool = { NSApplication.shared.isFullKeyboardAccessEnabled }

    /// Set while a recording this field started runs.
    private var start: Start?
    /// The window whose resign-key notice the field watches.
    private weak var watchedWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { keyboardNavigation() && super.canBecomeKeyView }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
    }

    override func becomeFirstResponder() -> Bool {
        refresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording(keepsFocus: true)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard window != nil, newWindow !== window else { return }
        stopRecording(keepsFocus: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch(window)
    }

    override func mouseDown(with event: NSEvent) {
        // A Command-click reaches a window that isn't key without making it key, and no key would
        // reach a recording there.
        if event.modifierFlags.contains(.command), window?.isKeyWindow != true { return }
        // The second click of a double-click would stop the recording the first one started. Any
        // other click counts, however soon it follows the one before, so a quick click after a
        // recording ended starts the next one.
        if event.clickCount > 1, start == .click, model?.isRecording == true { return }
        toggleRecording(.click)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isHeldPress(event) { return }
        if model?.isRecording == false, Self.isPress(event) {
            startRecording(.keyboard)
            return
        }
        if !record(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if Self.isHeldPress(event) { return true }
        return record(event) || super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        model?.modifiersChanged(Self.modifiers(event))
        refresh()
        super.flagsChanged(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        // Unlike a click, a press doesn't make the window key. In a window that isn't key no key
        // would reach the recording, and no resign-key notice would end it.
        if model?.isRecording != true, window?.isKeyWindow != true { return false }
        return toggleRecording(.keyboard)
    }

    /// Ends the recording when a click lands anywhere in the window but on the field.
    /// ``SettingsWindow`` calls it before it handles the click.
    func windowWillHandleMouseDown(at point: NSPoint) {
        guard model?.isRecording == true, let window, let top = window.contentView?.superview ?? window.contentView
        else { return }
        if let hit = top.hitTest(point), hit.isDescendant(of: self) { return }
        stopRecording(keepsFocus: start != .click)
    }

    // MARK: Recording

    /// Stops the recording that runs, or starts one. Returns false when none could start.
    @discardableResult
    private func toggleRecording(_ how: Start) -> Bool {
        guard let model else { return false }
        if model.isRecording {
            stopRecording(keepsFocus: start != .click)
            return true
        }
        return startRecording(how)
    }

    /// Takes focus and starts a recording. Does nothing in a window that can never be key, because
    /// no key would reach the field there.
    @discardableResult
    private func startRecording(_ how: Start) -> Bool {
        guard let model, let window, window.canBecomeKey else { return false }
        if window.firstResponder !== self {
            guard window.makeFirstResponder(self) else { return false }
        }
        start = how
        model.beginRecording()
        refresh()
        return true
    }

    /// Ends the recording that runs, if any. Without `keepsFocus`, the field gives up focus.
    private func stopRecording(keepsFocus: Bool) {
        start = nil
        model?.endRecording()
        refresh()
        if !keepsFocus { releaseFocus() }
    }

    /// Called after the model left recording on its own, as a key press took, refused or cancelled a
    /// combination. A recording that a click started gives up focus.
    private func recordingEnded() {
        let how = start
        start = nil
        if how == .click { releaseFocus() }
    }

    private func releaseFocus() {
        if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
    }

    /// Watches a window for the notice that it stopped being key.
    private func watch(_ window: NSWindow?) {
        guard window !== watchedWindow else { return }
        let center = NotificationCenter.default
        if let watchedWindow {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: watchedWindow)
        }
        watchedWindow = window
        if let window {
            center.addObserver(
                self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification,
                object: window)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard model?.isRecording == true else { return }
        stopRecording(keepsFocus: start != .click)
    }

    /// Space, Return and the keypad's Enter: the keys that press a focused button.
    private static let pressKeys: Set<Key> = [.space, .return, Key(code: 0x4C)]

    /// One of ``pressKeys`` with no modifier.
    private static func isPress(_ event: NSEvent) -> Bool {
        event.type == .keyDown && modifiers(event).isEmpty && pressKeys.contains(Key(code: event.keyCode))
    }

    /// A press key held down long enough to repeat. The field ignores it, so a held Space neither
    /// ends the recording it started nor starts another.
    private static func isHeldPress(_ event: NSEvent) -> Bool {
        isPress(event) && event.isARepeat
    }

    /// Hands one key press to the model. Returns whether it was used.
    private func record(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let model else { return false }
        let used = model.handle(key: Key(code: event.keyCode), modifiers: Self.modifiers(event))
        if used && !model.isRecording { recordingEnded() }
        refresh()
        return used
    }

    private static func modifiers(_ event: NSEvent) -> KeyModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyModifiers(rawValue: UInt(flags.rawValue)).intersection(HotkeyRecorderModel.hotkeyModifiers)
    }

    /// Shows the model's state.
    func refresh() {
        needsDisplay = true
        guard let model else { return }
        if start != nil, !model.isRecording {
            // A button ended the recording, such as Clear. After a click's recording, focus moves
            // once SwiftUI's update is over.
            let how = start
            start = nil
            if how == .click {
                DispatchQueue.main.async { [weak self] in
                    if self?.model?.isRecording == false { self?.releaseFocus() }
                }
            }
        }
        setAccessibilityLabel(model.target.title)
        setAccessibilityValue(model.isRecording ? "Recording" : (model.combo?.displayString ?? "None"))
        setAccessibilityHelp(
            "Press to record a shortcut, and press again to stop. While it records, Escape stops recording and "
                + "Delete clears the shortcut.")
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
