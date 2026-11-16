import AppKit
import CoreText

/// The filter dropdown at the trailing end of the query row: the selected option's title and a
/// chevron in an inset capsule. A click, or `QueryField.openFilterMenu()` for Command-P, opens
/// its options as a menu inside the panel. It never takes focus from the query text.
final class FilterChipView: NSView {
    /// An option was chosen.
    var onChoose: ((MenuOption) -> Void)?

    private(set) var filter: QueryFilter
    private var theme: ResolvedTheme?
    private var chevron: CGImage?

    init(filter: QueryFilter) {
        self.filter = filter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(filter.label)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ filter: QueryFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        setAccessibilityLabel(filter.label)
        needsDisplay = true
    }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        let chips = theme.theme.chips
        layer?.cornerRadius = CGFloat(chips.height) / 2
        layer?.backgroundColor = theme.form.fieldFill
        chevron = SymbolRenderer.image(
            "chevron.down", pointSize: CGFloat(chips.chevronSize), weight: .semibold, color: theme.subtitle,
            scale: window?.backingScaleFactor ?? 2)
        needsDisplay = true
    }

    /// The width the selected title and the chevron need.
    var fittingWidth: CGFloat {
        guard let theme else { return 0 }
        let chips = theme.theme.chips
        let width = ceil((filter.selectedTitle as NSString).size(withAttributes: [.font: theme.form.chipFont]).width)
        return width + CGFloat(chips.padding) * 2.5 + CGFloat(chips.chevronSize)
    }

    override func mouseDown(with event: NSEvent) {
        openMenu()
    }

    /// Shows the options under the chip, aligned to its trailing edge.
    func openMenu() {
        guard let surface = (window as? GlassPanel)?.surface else { return }
        let menu = DropdownMenuView(
            options: filter.options, selectedID: filter.selectedID,
            placement: .below(convert(bounds, to: surface.overlaySpace), trailingAligned: true))
        menu.onChoose = { [weak self] option in
            guard let self, option.id != filter.selectedID else { return }
            filter.selectedID = option.id
            needsDisplay = true
            onChoose?(option)
        }
        surface.present(menu)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let chips = theme.theme.chips
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(chips.padding)
        let size = CGFloat(chips.chevronSize)
        if let chevron {
            let frame = CGRect(
                x: bounds.width - padding - size, y: RowTypesetter.snap((bounds.height - size) / 2, scale), width: size,
                height: size)
            RowRenderer.drawImage(chevron, in: frame, context: context)
        }
        let font = theme.form.chipFont as CTFont
        let line = RowTypesetter.truncate(
            CTLineCreateWithAttributedString(
                RowTypesetter.attributed(filter.selectedTitle, font: font, color: theme.title)),
            to: max(0, bounds.width - padding * 2.5 - size), font: font, color: theme.title)
        let baseline = RowTypesetter.snap(RowTypesetter.baseline(centering: font, in: bounds.height), scale)
        RowRenderer.draw(.init(line: line, origin: CGPoint(x: padding, y: baseline)), context)
    }

    override func accessibilityValue() -> Any? { filter.selectedTitle }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }
}
