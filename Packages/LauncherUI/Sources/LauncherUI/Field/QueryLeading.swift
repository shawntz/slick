import AppKit

/// What the query row shows before the text: a magnifier at root, or a back chevron with the
/// name of the current view inside one.
nonisolated public struct QueryLeading: Sendable, Equatable {
    /// The glyph in the 20 pt leading slot.
    public enum Glyph: Sendable, Equatable {
        case magnifier
        case back

        var symbolName: String {
            switch self {
            case .magnifier: "magnifyingglass"
            case .back: "chevron.left"
            }
        }
    }

    public var glyph: Glyph
    /// The current view's name in a capsule after the glyph, or nil for none.
    public var breadcrumb: String?

    public init(glyph: Glyph, breadcrumb: String? = nil) {
        self.glyph = glyph
        self.breadcrumb = breadcrumb
    }

    /// The root look: a magnifier and no breadcrumb.
    public static let root = QueryLeading(glyph: .magnifier)
}

/// The breadcrumb capsule: a tinted capsule with the view's name.
final class BreadcrumbCapsule: NSView {
    let label = NSTextField(labelWithString: "")
    private var padding: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ theme: ResolvedTheme) {
        label.font = theme.theme.fonts.breadcrumb.nsFont
        padding = theme.theme.queryRow.breadcrumbPadding
        layer?.backgroundColor = theme.keycapFill
        needsLayout = true
    }

    /// Width for the current title, capped at `maximum`.
    func width(maximum: CGFloat) -> CGFloat {
        min(maximum, ceil(label.attributedStringValue.size().width) + padding * 2 + 4)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: padding, y: (bounds.height - height) / 2, width: max(0, bounds.width - padding * 2), height: height
        )
    }
}
