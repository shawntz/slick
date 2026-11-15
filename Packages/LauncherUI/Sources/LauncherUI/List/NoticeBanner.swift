import AppKit
import CoreText

/// What a notice banner shows.
nonisolated public struct NoticeContent: Sendable, Equatable {
    /// The icon before the title. Nil draws none.
    public var icon: CardIcon?
    public var title: String
    /// Drawn after the title in the secondary colour while it fits.
    public var message: String?
    /// A button at the trailing edge, such as "Grant Access". Nil draws none, and the banner then
    /// takes no clicks.
    public var buttonTitle: String?

    public init(
        icon: CardIcon? = .symbol("info.circle"), title: String, message: String? = nil, buttonTitle: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
    }
}

/// A banner above a list's or a grid's rows: an icon, a title, an optional message and an
/// optional button, drawn with Core Text in the theme's colours on an inset field, so it meets the
/// same contrast rules as the rows under it.
///
/// The host places it at the top of the content area, `preferredHeight` tall, and moves the rows
/// down by that much. A click anywhere on a banner with a button calls `onPress`.
public final class NoticeBanner: NSView {
    /// The banner was clicked or pressed through accessibility while it has a button.
    public var onPress: (() -> Void)?
    public private(set) var content = NoticeContent(icon: nil, title: "")

    private var theme: ResolvedTheme?
    private var iconImage: CGImage?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height the banner takes at the top of the content area: one list row plus the gap
    /// above and below its field.
    public static func preferredHeight(for theme: ResolvedTheme) -> CGFloat {
        let list = theme.theme.list
        return CGFloat(list.rowHeight + list.verticalPadding)
    }

    public func apply(_ content: NoticeContent) {
        guard content != self.content else { return }
        let iconChanged = content.icon != self.content.icon
        self.content = content
        if iconChanged { renderIcon() }
        setAccessibilityLabel([content.title, content.message].compactMap(\.self).joined(separator: ", "))
        if content.buttonTitle != nil {
            setAccessibilityRole(.button)
            setAccessibilityHelp(content.buttonTitle)
        } else {
            setAccessibilityRole(.group)
            setAccessibilityHelp(nil)
        }
        needsDisplay = true
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        renderIcon()
        needsDisplay = true
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderIcon()
    }

    private func renderIcon() {
        iconImage = nil
        guard let theme, let icon = content.icon else { return }
        switch icon {
        case .image(let image): iconImage = image
        case .symbol(let name):
            iconImage = SymbolRenderer.image(
                name, pointSize: CGFloat(theme.theme.list.accessoryIconSize), color: theme.subtitle,
                scale: window?.backingScaleFactor ?? 2)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        guard content.buttonTitle != nil else { return }
        onPress?()
    }

    override public func accessibilityPerformPress() -> Bool {
        guard content.buttonTitle != nil else { return false }
        onPress?()
        return true
    }

    // MARK: Layout and drawing

    /// Where each part goes, in the banner's coordinates.
    struct Placement {
        var field: CGRect
        var icon: CGRect?
        var title: RowTypeset.PlacedLine?
        var message: RowTypeset.PlacedLine?
        var button: CGRect?
        var buttonTitle: RowTypeset.PlacedLine?
    }

    func placement(theme: ResolvedTheme, scale: CGFloat) -> Placement {
        let list = theme.theme.list
        let gap = CGFloat(list.verticalPadding) / 2
        let field = CGRect(
            x: CGFloat(list.iconX), y: gap, width: max(0, bounds.width - CGFloat(list.iconX) * 2),
            height: max(0, bounds.height - gap * 2))
        var placed = Placement(field: field)
        let inset = CGFloat(list.sectionHeaderX) - CGFloat(list.iconX) + CGFloat(list.accessorySpacing)
        var x = field.minX + inset
        var right = field.maxX - inset / 2

        if iconImage != nil {
            let side = CGFloat(list.accessoryIconSize)
            placed.icon = CGRect(x: x, y: RowTypesetter.snap(field.midY - side / 2, scale), width: side, height: side)
            x += side + CGFloat(list.iconTextGap) - CGFloat(list.accessorySpacing)
        }
        if let buttonTitle = content.buttonTitle {
            let font = theme.subtitleFont
            let line = CTLineCreateWithAttributedString(
                RowTypesetter.attributed(buttonTitle, font: font, color: theme.keycapText))
            let height = CGFloat(list.tagHeight) + CGFloat(list.keycapPadding)
            let width = ceil(RowTypesetter.lineWidth(line)) + CGFloat(list.tagPadding) * 2
            let button = CGRect(
                x: right - width, y: RowTypesetter.snap(field.midY - height / 2, scale), width: width, height: height)
            placed.button = button
            placed.buttonTitle = RowTypesetter.centered(line, in: button, font: font, scale: scale)
            right = button.minX - CGFloat(list.accessoryGap)
        }
        let titleFont = theme.titleFont
        let baseline = RowTypesetter.snap(
            field.minY + RowTypesetter.baseline(centering: titleFont, in: field.height), scale)
        let fullTitle = CTLineCreateWithAttributedString(
            RowTypesetter.attributed(content.title, font: titleFont, color: theme.title))
        let title = RowTypesetter.truncate(fullTitle, to: max(0, right - x), font: titleFont, color: theme.title)
        placed.title = .init(line: title, origin: CGPoint(x: x, y: baseline))
        let titleWidth = RowTypesetter.lineWidth(title)
        let messageX = x + ceil(titleWidth) + CGFloat(list.titleSubtitleGap)
        if let message = content.message, !message.isEmpty, messageX + CGFloat(list.minimumSubtitleWidth) < right {
            let font = theme.subtitleFont
            let line = RowTypesetter.truncate(
                CTLineCreateWithAttributedString(RowTypesetter.attributed(message, font: font, color: theme.subtitle)),
                to: right - messageX, font: font, color: theme.subtitle)
            placed.message = .init(line: line, origin: CGPoint(x: messageX, y: baseline))
        }
        return placed
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext, !content.title.isEmpty else { return }
        let placed = placement(theme: theme, scale: window?.backingScaleFactor ?? 2)
        let radius = CGFloat(theme.theme.form.fieldCornerRadius)
        context.addPath(CGPath(roundedRect: placed.field, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(theme.form.fieldFill)
        context.fillPath()
        if let iconImage, let frame = placed.icon { RowRenderer.drawImage(iconImage, in: frame, context: context) }
        if let button = placed.button {
            let keycap = CGFloat(theme.theme.list.keycapRadius)
            context.addPath(CGPath(roundedRect: button, cornerWidth: keycap, cornerHeight: keycap, transform: nil))
            context.setFillColor(theme.keycapFill)
            context.fillPath()
        }
        RowRenderer.withHalo(theme, context) {
            for line in [placed.title, placed.message, placed.buttonTitle].compactMap(\.self) {
                RowRenderer.draw(line, context)
            }
        }
    }
}

extension NoticeBanner {
    /// The title, the message and the button's capsule, for contrast measurement.
    @_spi(Testing) public func drawnText() -> DrawnText {
        guard let theme, !content.title.isEmpty else { return DrawnText() }
        let placed = placement(theme: theme, scale: window?.backingScaleFactor ?? 2)
        var drawn = DrawnText()
        if let title = placed.title { drawn.titles.append(DrawnText.frame(title, font: theme.titleFont)) }
        if let message = placed.message { drawn.secondary.append(DrawnText.frame(message, font: theme.subtitleFont)) }
        if let button = placed.button { drawn.capsules.append(button) }
        return drawn
    }
}
