import AppKit

/// Receives what the user does in the query field.
public protocol QueryFieldDelegate: AnyObject {
    /// The committed text changed. Never called while an input method is composing text.
    func queryField(_ field: QueryField, didChangeText text: String)
    /// A key the field does not handle itself. Return true when the host handled it.
    func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool
    /// The argument at `index` changed: its text, or its chosen option's id.
    func queryField(_ field: QueryField, argumentAt index: Int, didChange value: String)
    /// An option was chosen in the filter dropdown.
    func queryField(_ field: QueryField, didChooseFilter option: MenuOption)
}

extension QueryFieldDelegate {
    public func queryField(_ field: QueryField, argumentAt index: Int, didChange value: String) {}
    public func queryField(_ field: QueryField, didChooseFilter option: MenuOption) {}
}

/// The query row: a leading slot, the search text with a ghost completion or up to three argument
/// chips after it, and a trailing slot for a spinner and the filter dropdown.
///
/// The text is a real `NSTextField`, so it keeps vibrancy, IME, undo, dictation and accessibility.
/// Its field editor is the panel's tuned TextKit 1 editor and stays installed across summons.
public final class QueryField: NSView, NSTextFieldDelegate {
    public weak var delegate: (any QueryFieldDelegate)?
    /// The text field itself. Hosts read it for accessibility or focus; set text through `text`.
    public let textField = QueryTextField()

    /// The glyph and breadcrumb before the text.
    public var leading: QueryLeading = .root {
        didSet { if leading != oldValue { applyLeading() } }
    }

    /// A view after the text, such as a spinner or argument chips. Its frame width is kept; its
    /// height is centred in the row.
    public var trailingView: NSView? {
        didSet {
            guard trailingView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let trailingView { addSubview(trailingView) }
            needsLayout = true
        }
    }

    /// Inline arguments after the text, such as a command's title: at most the theme's
    /// `maxArguments`. Tab and Shift-Tab move between the text and the chips, as do Left and Right
    /// at either end of a chip's text. While arguments show, the ghost completion does not.
    public var arguments: [QueryArgument] = [] {
        didSet { if arguments != oldValue { rebuildArgumentChips() } }
    }

    /// The filter dropdown in the trailing slot, or nil for none.
    public var filter: QueryFilter? {
        didSet { if filter != oldValue { rebuildFilterChip() } }
    }

    /// Text drawn after the typed text in the placeholder colour, such as the rest of the top
    /// result's title. Shown only while the caret is at the end and nothing is being composed.
    public var ghostText: String = "" {
        didSet { if ghostText != oldValue { placeGhost() } }
    }

    public var placeholder: String = "" {
        didSet { if placeholder != oldValue { applyPlaceholder() } }
    }

    /// The committed text. Setting it does not call the delegate, and leaves the caret at the end.
    public var text: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            if let editor = textField.currentEditor() {
                editor.selectedRange = NSRange(location: (newValue as NSString).length, length: 0)
            }
            placeGhost()
        }
    }

    /// Where the ghost text is drawn, or nil while it is hidden.
    var ghostFrame: CGRect? { ghost.isHidden ? nil : ghost.frame }

    /// Whether an input method is composing text right now.
    public var hasMarkedText: Bool { (textField.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    let glyphView = LeadingGlyphView()
    let breadcrumb = BreadcrumbCapsule()
    private let ghost = GhostTextView()
    /// Where the ghost goes for the current text, or nil when it does not fit.
    private var ghostOrigin: CGPoint?
    private(set) var theme: ResolvedTheme?
    /// One chip per shown argument, in order.
    var argumentChips: [ArgumentChipView] = []
    var filterChip: FilterChipView?
    /// Clips the text before the argument chips.
    let textMask: CALayer = {
        let mask = CALayer()
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)
        return mask
    }()
    private var selectionObserver: (any NSObjectProtocol)?

    override public var isFlipped: Bool { true }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.textColor = .labelColor
        textField.allowsWritingTools = false
        textField.delegate = self
        glyphView.imageScaling = .scaleNone
        glyphView.contentTintColor = .secondaryLabelColor
        glyphView.onPress = { [weak self] in self?.goBack() }
        ghost.isHidden = true
        breadcrumb.isHidden = true
        for view in [glyphView, breadcrumb, textField, ghost] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    }

    /// Restyles the row for a resolved theme.
    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        textField.font = theme.queryFont
        ghost.apply(theme)
        breadcrumb.apply(theme)
        for chip in argumentChips { chip.apply(theme) }
        filterChip?.apply(theme)
        applyLeading()
        applyPlaceholder()
        needsLayout = true
    }

    /// Makes the text field first responder, which installs the field editor. Call once while
    /// pre-warming; the editor then stays installed and the summon path never repeats it.
    public func installEditor() {
        window?.makeFirstResponder(textField)
        guard selectionObserver == nil, let editor = textField.currentEditor() else { return }
        // Composition changes the selection but not the committed text, so hide the ghost here.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: editor, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOrHideGhost() }
        }
    }

    // MARK: Layout

    override public func layout() {
        super.layout()
        guard let theme else { return }
        let metrics = theme.theme.queryRow
        let height = bounds.height
        var x = CGFloat(metrics.leadingInset)
        let slot = CGFloat(metrics.glyphSlotWidth)
        glyphView.frame = NSRect(x: x, y: 0, width: slot, height: height)
        x += slot
        if !breadcrumb.isHidden {
            x += CGFloat(metrics.textGap) / 2
            let capsuleHeight = CGFloat(metrics.breadcrumbHeight)
            let width = breadcrumb.width(maximum: bounds.width * CGFloat(metrics.breadcrumbMaxFraction))
            breadcrumb.frame = NSRect(
                x: x, y: ((height - capsuleHeight) / 2).rounded(), width: width, height: capsuleHeight)
            x += width
        }
        x += CGFloat(metrics.textGap)
        var right = bounds.width - CGFloat(metrics.trailingInset)
        if let filterChip {
            let chips = theme.theme.chips
            let width = filterChip.fittingWidth
            filterChip.frame = NSRect(
                x: right - width, y: ((height - CGFloat(chips.height)) / 2).rounded(), width: width,
                height: CGFloat(chips.height))
            right -= width + CGFloat(chips.spacing)
        }
        if let trailingView {
            let size = trailingView.frame.size
            trailingView.frame = NSRect(
                x: right - size.width, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height
            )
            right -= size.width + CGFloat(metrics.trailingInset)
        }
        // The field draws its text 2 pt in from its frame, so start it 2 pt early.
        let fieldHeight = ceil(theme.queryFont.ascender - theme.queryFont.descender + theme.queryFont.leading) + 4
        textField.frame = NSRect(
            x: x - 2, y: ((height - fieldHeight) / 2).rounded(), width: max(0, right - x + 2), height: fieldHeight)
        textArea = (x, right)
        placeArgumentChips()
        placeGhost()
    }

    /// Where the text may go, between the leading slot and the trailing views.
    var textArea: (minX: CGFloat, maxX: CGFloat) = (0, 0)

    override public func hitTest(_ point: NSPoint) -> NSView? {
        // The whole leading slot and the breadcrumb answer a click with Back.
        let local = convert(point, from: superview)
        if leading.glyph == .back, local.x < breadcrumbOrGlyphMaxX { return glyphView }
        return super.hitTest(point)
    }

    private var breadcrumbOrGlyphMaxX: CGFloat {
        breadcrumb.isHidden ? glyphView.frame.maxX : breadcrumb.frame.maxX
    }

    private func goBack() {
        _ = delegate?.queryField(self, perform: .back)
    }

    // MARK: Text field delegate

    public func controlTextDidChange(_ notification: Notification) {
        if !argumentChips.isEmpty { placeArgumentChips() }
        placeGhost()
        guard !hasMarkedText else { return }
        delegate?.queryField(self, didChangeText: textField.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let modifiers = NSApp.currentEvent.flatMap { KeyChord(event: $0)?.modifiers } ?? []
        let command: QueryCommand
        switch selector {
        case #selector(NSResponder.moveUp(_:)): command = .moveUp
        case #selector(NSResponder.moveDown(_:)): command = .moveDown
        case #selector(NSResponder.moveLeft(_:)): command = .moveLeft
        case #selector(NSResponder.moveRight(_:)):
            if !argumentChips.isEmpty,
                textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0)
            {
                focusArgument(0)
                return true
            }
            command = .moveRight
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): command = .moveToPreviousSection
        case #selector(NSResponder.moveToEndOfDocument(_:)): command = .moveToNextSection
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            command = .submit(modifiers)
        case #selector(NSResponder.cancelOperation(_:)): command = .cancel(modifiers)
        case #selector(NSResponder.insertTab(_:)):
            if !argumentChips.isEmpty {
                focusArgument(0)
                return true
            }
            command = .complete
        case #selector(NSResponder.insertBacktab(_:)): command = .completeBackward
        case #selector(NSResponder.deleteBackward(_:)):
            guard textField.stringValue.isEmpty else { return false }
            command = .deleteOnEmpty
        default:
            return false
        }
        let handled = delegate?.queryField(self, perform: command) ?? false
        switch command {
        // The field's own handling of these would end editing and drop the installed editor.
        case .submit, .cancel, .complete, .completeBackward: return true
        default: return handled
        }
    }

    /// Offers a Command chord to the host. The panel calls this before the menus see the event,
    /// so a chord the host does not claim still reaches the Edit menu.
    public func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !hasMarkedText, let chord = KeyChord(event: event),
            chord.modifiers.contains(.command)
        else { return false }
        let modifiers = chord.modifiers
        let command: QueryCommand
        switch chord.key {
        case KeyChord.Key.up where modifiers == .command: command = .moveToPreviousSection
        case KeyChord.Key.down where modifiers == .command: command = .moveToNextSection
        case KeyChord.Key.returnKey: command = .submit(modifiers)
        case KeyChord.Key.escape: command = .cancel(modifiers)
        default: command = .chord(chord)
        }
        return delegate?.queryField(self, perform: command) ?? false
    }

    // MARK: Pieces

    private func applyLeading() {
        let pointSize = CGFloat(theme?.theme.queryRow.glyphSize ?? 17)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        glyphView.image = NSImage(systemSymbolName: leading.glyph.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        breadcrumb.label.stringValue = leading.breadcrumb ?? ""
        breadcrumb.isHidden = leading.breadcrumb == nil
        glyphView.isBackButton = leading.glyph == .back
        needsLayout = true
    }

    private func applyPlaceholder() {
        guard let theme else { return }
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.font: theme.queryFont, .foregroundColor: NSColor.tertiaryLabelColor]
        )
    }

    /// Places the ghost right after the typed text, using the field editor's own layout so it
    /// follows horizontal scrolling. Runs when the text, the ghost or the layout changes.
    func placeGhost() {
        ghostOrigin = nil
        defer { showOrHideGhost() }
        guard !ghostText.isEmpty, argumentChips.isEmpty, !textField.stringValue.isEmpty,
            let editor = textField.currentEditor() as? NSTextView, !editor.hasMarkedText(),
            let layoutManager = editor.layoutManager, let container = editor.textContainer
        else { return }
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        let used = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = line.minY + layoutManager.location(forGlyphAt: 0).y
        let origin = editor.textContainerOrigin
        let end = editor.convert(NSPoint(x: origin.x + used.maxX, y: origin.y + baseline), to: self)
        let limit = textField.frame.maxX - Self.fieldTextInset
        guard end.x < limit - Self.minimumGhostWidth else { return }
        ghostOrigin = end
        ghost.text = ghostText
        let field = textField.frame
        ghost.frame = NSRect(x: end.x, y: field.minY, width: limit - end.x, height: field.height)
        ghost.baseline = end.y - field.minY
    }

    /// Shows the ghost only while the caret is at the end and nothing is being composed. Runs on
    /// every selection change, so it only reads state.
    private func showOrHideGhost() {
        guard ghostOrigin != nil, let editor = textField.currentEditor() as? NSTextView, !editor.hasMarkedText(),
            editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0)
        else {
            ghost.isHidden = true
            return
        }
        ghost.isHidden = false
    }

    /// The field draws its text this far in from its frame.
    private static let fieldTextInset: CGFloat = 2
    /// A ghost narrower than this is not worth showing.
    private static let minimumGhostWidth: CGFloat = 8
}

/// The query text field. It reports itself to accessibility as the search field.
public final class QueryTextField: NSTextField {
    override public func accessibilitySubrole() -> NSAccessibility.Subrole? { .searchField }
}
