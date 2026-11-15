import AppKit

/// A view inside the panel that wants key equivalents before the host's handler, while it or a
/// view inside it has keyboard focus.
@MainActor protocol PanelKeyHandling: AnyObject {
    /// Return true when the event was handled.
    func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool
}

/// The launcher window: a borderless, non-activating, floating panel.
///
/// - It takes real key status, so typing reaches the query field and the glass shows its full
///   look, while the user's app stays frontmost and keeps its menu bar and title bar.
/// - It is never main, so it never joins the app's window ordering or menus.
/// - It has no window-server shadow and a clear background. The glass draws its own shadow,
///   which is why the window is larger than the glass (see `PanelGeometry`).
/// - `ignoresMouseEvents` is never set: the window server already passes clicks outside the
///   glass shape through to the window below, and setting it to false would stop that.
public final class GlassPanel: NSPanel {
    /// Offered every key equivalent before the view hierarchy and the main menu see it. Return
    /// true when handled. Command-A, C, V, X and Z fall through to the Edit menu when it returns
    /// false.
    public var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Called after the panel loses key status, for example when the user clicks another app.
    public var onResignKey: (() -> Void)?

    /// The field editor every `NSTextField` in the panel uses. It stays installed across summons
    /// so the summon path never calls `makeFirstResponder`.
    public let queryFieldEditor: NSTextView = QueryFieldEditor.make()

    public init(contentRect: NSRect) {
        // defer: false creates the window-server window now, as part of pre-warming.
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // An accessory app's panel would otherwise be offered to window pickers and restored.
        isExcludedFromWindowsMenu = true
        isRestorable = false
    }

    // A borderless window refuses key status unless it says otherwise.
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    override public func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A view on the focus path that claims chords, such as a hotkey recorder or a form, sees
        // them before the host does.
        var responder = firstResponder
        while let current = responder {
            if let handler = current as? any PanelKeyHandling, handler.handlePanelKeyEquivalent(event) { return true }
            responder = current.nextResponder
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The panel's text fields share the tuned editor. A secure field keeps AppKit's own secure
    /// editor, which hides what is typed and keeps it out of the pasteboard.
    override public func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is NSTextField, !(object is NSSecureTextField) { return queryFieldEditor }
        return super.fieldEditor(createFlag, for: object)
    }

    /// The surface that owns this panel, so views inside it can present cards and menus.
    weak var surface: LauncherSurface?

    /// Installs an Edit menu as the app's main menu. An accessory app never shows it, but without
    /// it Command-A, C, V, X and Z do nothing in the query field. Call once at launch.
    public static func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
