import AppKit
import CoreText

/// Words added as capsules: type one and press Return or a comma to add it, press Delete in the
/// empty input to remove the last one. The field grows a line at a time as tags wrap.
///
/// With suggestions, the first one that starts with the typed text shows as a ghost completion.
/// Return adds the completed word, Right Arrow at the end fills it in, and Down Arrow lists every
/// suggestion that matches in a menu inside the panel.
final class TagFormControl: FormControlView {
    private(set) var tags: [String] = []
    let field = PanelTextField()
    private let ghost = GhostTextView()
    private var layoutCache: (tags: [CGRect], field: CGRect, lines: Int)?
    private(set) var suggestions: [String] = []
    /// The suggestion the ghost completes to, or nil.
    private(set) var completion: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(field)
        ghost.isHidden = true
        addSubview(ghost)
        field.relay.onChange = { [weak self] text in self?.textChanged(text) }
        field.relay.onCommand = { [weak self] selector in self?.command(selector) ?? false }
        field.relay.onEndEditing = { [weak self] in
            self?.ghost.isHidden = true
            self?.reportFocus(false)
        }
        field.onFocus = { [weak self] in
            self?.reportFocus(true)
            self?.refreshCompletion()
        }
    }

    required init?(coder: NSCoder) { nil }

    override var value: FormValue { .tags(tags) }
    override var firstKeyView: NSView { field }
    override var lastKeyView: NSView { field }

    override func setValue(_ value: FormValue) {
        guard case .tags(let tags) = value, tags != self.tags else { return }
        self.tags = tags
        changedLayout()
    }

    override func update(_ kind: FormItem.Kind) {
        if case .tags(let placeholder) = kind { field.setPlaceholder(placeholder) }
    }

    override func configure(_ item: FormItem) {
        super.configure(item)
        guard item.suggestions != suggestions else { return }
        suggestions = item.suggestions
        refreshCompletion()
    }

    override func apply(_ theme: ResolvedTheme) {
        field.font = theme.form.controlFont
        field.placeholderColor = NSColor(cgColor: theme.ghostText) ?? .tertiaryLabelColor
        ghost.style(font: theme.form.controlFont as CTFont, color: theme.ghostText)
        super.apply(theme)
        changedLayout()
    }

    override func selectText(_ range: NSRange) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        editor.selectedRange = PlaceholderHighlighter.clamped(range, length: (editor.string as NSString).length)
        return true
    }

    override func preferredHeight(width: CGFloat) -> CGFloat? {
        guard let theme else { return nil }
        return CGFloat(flow(width: width, theme: theme).lines) * CGFloat(theme.theme.form.controlHeight)
    }

    // MARK: Editing

    private func textChanged(_ text: String) {
        defer { refreshCompletion() }
        guard text.contains(",") else { return }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        for part in parts.dropLast() { add(String(part)) }
        field.stringValue = String(parts.last ?? "")
    }

    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:))
        where !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty:
            add(completion ?? field.stringValue)
            field.stringValue = ""
            refreshCompletion()
            return true
        case #selector(NSResponder.moveRight(_:)) where completion != nil && caretIsAtEnd:
            field.stringValue = completion ?? ""
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            refreshCompletion()
            return true
        case #selector(NSResponder.moveDown(_:)):
            return openSuggestions()
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && !tags.isEmpty:
            tags.removeLast()
            changedLayout()
            onChange?(.tags(tags))
            return true
        default:
            return handleTextCommand(selector, in: field)
        }
    }

    private func add(_ text: String) {
        let tag = text.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        changedLayout()
        onChange?(.tags(tags))
    }

    // MARK: Suggestions

    private var caretIsAtEnd: Bool {
        guard let editor = field.currentEditor() else { return false }
        return editor.selectedRange == NSRange(location: (editor.string as NSString).length, length: 0)
    }

    private func refreshCompletion() {
        completion = TagSuggestions.completion(for: field.stringValue, in: suggestions, excluding: tags)
        placeGhost()
    }

    /// Lists the suggestions that match the typed text in a menu under the field. Returns false
    /// when none does.
    private func openSuggestions() -> Bool {
        let matches = TagSuggestions.matches(for: field.stringValue, in: suggestions, excluding: tags)
        guard !matches.isEmpty, let surface = (window as? GlassPanel)?.surface else { return false }
        let menu = DropdownMenuView(
            options: matches.map { MenuOption(id: $0, title: $0) }, selectedID: nil,
            placement: .below(convert(bounds, to: surface.overlaySpace), trailingAligned: false))
        menu.onChoose = { [weak self] option in
            guard let self else { return }
            add(option.id)
            field.stringValue = ""
            refreshCompletion()
        }
        surface.present(menu)
        return true
    }

    /// Puts the ghost right after the typed text, using the field editor's own layout.
    private func placeGhost() {
        let typed = field.stringValue
        guard let completion, !typed.isEmpty, caretIsAtEnd, let editor = field.currentEditor() as? NSTextView,
            !editor.hasMarkedText(), let layoutManager = editor.layoutManager, let container = editor.textContainer
        else {
            ghost.isHidden = true
            return
        }
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else {
            ghost.isHidden = true
            return
        }
        let used = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = line.minY + layoutManager.location(forGlyphAt: 0).y
        let origin = editor.textContainerOrigin
        let end = editor.convert(NSPoint(x: origin.x + used.maxX, y: origin.y + baseline), to: self)
        let limit = field.frame.maxX
        guard end.x < limit else {
            ghost.isHidden = true
            return
        }
        ghost.text = String(completion.dropFirst(typed.count))
        ghost.frame = NSRect(x: end.x, y: field.frame.minY, width: limit - end.x, height: field.frame.height)
        ghost.baseline = end.y - field.frame.minY
        ghost.isHidden = false
    }

    private func changedLayout() {
        layoutCache = nil
        needsLayout = true
        needsDisplay = true
        onHeightChange?()
    }

    // MARK: Layout and drawing

    private func flow(width: CGFloat, theme: ResolvedTheme) -> (tags: [CGRect], field: CGRect, lines: Int) {
        if let layoutCache, bounds.width == width { return layoutCache }
        let form = theme.theme.form
        let list = theme.theme.list
        let widths = tags.map { tag in
            Double(ceil(RowTypesetter.lineWidth(line(tag, theme)) + CGFloat(list.tagPadding) * 2))
        }
        // The input keeps room for a short word before it wraps to a new line.
        let result = TagFlow.layout(
            widths: widths, fieldWidth: form.controlHeight * 3, width: Double(width), lineHeight: form.controlHeight,
            tagHeight: form.tagHeight, spacing: form.tagSpacing, padding: form.fieldPadding / 2)
        if bounds.width == width { layoutCache = result }
        return result
    }

    private func line(_ tag: String, _ theme: ResolvedTheme) -> CTLine {
        CTLineCreateWithAttributedString(
            RowTypesetter.attributed(tag, font: theme.tagFont, color: theme.tagColors(ThemeColor(.accent)).text))
    }

    override func layout() {
        super.layout()
        guard let theme else { return }
        let placed = flow(width: bounds.width, theme: theme)
        let height = field.lineHeight
        let padding = CGFloat(theme.theme.form.fieldPadding) / 2
        field.setFrameIfChanged(
            CGRect(
                x: placed.field.minX + padding - 2,
                y: placed.field.minY + ((placed.field.height - height) / 2).rounded(),
                width: max(0, placed.field.width - padding), height: height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let colors = theme.tagColors(ThemeColor(.accent))
        for (tag, frame) in zip(tags, flow(width: bounds.width, theme: theme).tags) {
            context.addPath(
                CGPath(
                    roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
            context.setFillColor(colors.fill)
            context.fillPath()
            let text = RowTypesetter.truncate(
                line(tag, theme), to: frame.width - CGFloat(theme.theme.list.tagPadding), font: theme.tagFont,
                color: colors.text)
            RowRenderer.draw(RowTypesetter.centered(text, in: frame, font: theme.tagFont, scale: scale), context)
        }
    }

    override func accessibilityValue() -> Any? { tags.joined(separator: ", ") }
}

/// Which suggestions a tag field offers for the typed text. Matching ignores case and diacritics.
nonisolated enum TagSuggestions {
    /// The first suggestion that starts with `typed` and is longer, skipping tags already added.
    static func completion(for typed: String, in suggestions: [String], excluding tags: [String]) -> String? {
        let needle = typed.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, needle == typed else { return nil }
        return suggestions.first { suggestion in
            suggestion.count > needle.count && !tags.contains(suggestion)
                && suggestion.range(of: needle, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Every suggestion not yet added that starts with `typed`, then every one with a word that
    /// does. All of them when nothing is typed.
    static func matches(for typed: String, in suggestions: [String], excluding tags: [String]) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespaces)
        let open = suggestions.filter { !tags.contains($0) }
        guard !needle.isEmpty else { return open }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let starts = open.filter { $0.range(of: needle, options: options.union(.anchored)) != nil }
        let words = open.filter { suggestion in
            !starts.contains(suggestion)
                && suggestion.split(separator: " ").contains {
                    $0.range(of: needle, options: options.union(.anchored)) != nil
                }
        }
        return starts + words
    }
}
