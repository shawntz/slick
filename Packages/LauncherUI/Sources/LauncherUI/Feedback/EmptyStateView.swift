import AppKit

/// What a view shows when it has nothing to list.
nonisolated public struct EmptyStateContent: Sendable, Equatable {
    /// An SF Symbol drawn large in the tertiary colour.
    public var symbolName: String?
    public var title: String
    /// A short hint under the title, such as what to type.
    public var hint: String?

    public init(symbolName: String? = nil, title: String, hint: String? = nil) {
        self.symbolName = symbolName
        self.title = title
        self.hint = hint
    }
}

/// The empty state: a large symbol, a title and a hint, centred in the content area. The title is
/// a vibrant label: it changes only when the view changes, never per keystroke. The hint takes
/// the theme's secondary colour, as `StaticLabel` explains.
public final class EmptyStateView: NSView, LauncherContentView {
    public var contentHeightDidChange: (() -> Void)?
    /// Unused: an empty state shows no selection.
    public weak var selectionLens: SelectionLens?
    public private(set) var content = EmptyStateContent(title: "")

    private let symbol = NSImageView()
    private let titleLabel = FixedLabel()
    private let hintLabel = StaticWrappingLabel(wrappingLabelWithString: "")
    private var theme: ResolvedTheme?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.setAccessibilityElement(false)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.isSelectable = false
        for view in [symbol, titleLabel, hintLabel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        content.title.isEmpty ? 0 : min(limit, CGFloat(theme?.theme.feedback.emptyStateHeight ?? 0))
    }

    public func apply(_ content: EmptyStateContent) {
        guard content != self.content else { return }
        let wasEmpty = self.content.title.isEmpty
        self.content = content
        titleLabel.stringValue = content.title
        hintLabel.stringValue = content.hint ?? ""
        hintLabel.isHidden = content.hint == nil
        setAccessibilityLabel([content.title, content.hint].compactMap(\.self).joined(separator: ". "))
        applySymbol()
        needsLayout = true
        if wasEmpty != content.title.isEmpty { contentHeightDidChange?() }
    }

    /// Where the title's text and the hint's first line are, for inspection.
    var titleTextFrame: CGRect {
        titleLabel.oneLineTextFrame.map { titleLabel.convert($0, to: self) } ?? titleLabel.frame
    }
    var hintLineFrame: CGRect? {
        guard !hintLabel.isHidden, let font = hintLabel.font else { return nil }
        let width = min(hintLabel.frame.width, ceil(hintLabel.attributedStringValue.size().width))
        return CGRect(
            x: hintLabel.frame.midX - width / 2, y: hintLabel.frame.minY, width: width,
            height: ceil(font.ascender - font.descender))
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        titleLabel.font = theme.feedback.emptyTitleFont
        hintLabel.font = theme.feedback.emptyHintFont
        hintLabel.textColor = NSColor(cgColor: theme.subtitle)
        symbol.contentTintColor = theme.emptySymbol
        applySymbol()
        needsLayout = true
    }

    private func applySymbol() {
        let size = CGFloat(theme?.theme.feedback.emptySymbolSize ?? Theme.standard.feedback.emptySymbolSize)
        symbol.image = content.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        symbol.isHidden = symbol.image == nil
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        guard let theme else { return }
        let feedback = theme.theme.feedback
        let height = preferredContentHeight(limit: bounds.height)
        let symbolSize = symbol.isHidden ? 0 : ceil(symbol.image?.size.height ?? 0)
        let titleHeight = titleLabel.lineHeight
        let hintWidth = min(bounds.width, CGFloat(feedback.emptyHintWidth))
        let hintHeight =
            hintLabel.isHidden
            ? 0
            : ceil(
                hintLabel.cell?.cellSize(
                    forBounds: CGRect(x: 0, y: 0, width: hintWidth, height: .greatestFiniteMagnitude)
                )
                .height ?? 0)
        var total = titleHeight
        if symbolSize > 0 { total += symbolSize + CGFloat(feedback.emptyTitleGap) }
        if hintHeight > 0 { total += CGFloat(feedback.emptyHintGap) + hintHeight }
        var y = ((height - total) / 2).rounded()
        if symbolSize > 0 {
            symbol.frame = CGRect(x: 0, y: y, width: bounds.width, height: symbolSize)
            y += symbolSize + CGFloat(feedback.emptyTitleGap)
        }
        titleLabel.frame = CGRect(x: 0, y: y, width: bounds.width, height: titleHeight)
        y += titleHeight + CGFloat(feedback.emptyHintGap)
        hintLabel.frame = CGRect(
            x: ((bounds.width - hintWidth) / 2).rounded(), y: y, width: hintWidth, height: hintHeight)
    }
}
