import AppKit

/// A vibrant text label whose frame its owner sets by hand.
///
/// It reports no intrinsic size, so changing its text never asks the window's layout engine for
/// a pass. The glass hosts SwiftUI, which gives the panel an engine, and a plain label's text
/// change ran it on every keystroke.
class FixedLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        lineBreakMode = .byTruncatingTail
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    /// The width the current text needs.
    var textWidth: CGFloat { ceil(attributedStringValue.size().width) + Self.slack }

    /// The height of one line in the label's font.
    var lineHeight: CGFloat {
        guard let font else { return 0 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// A label's frame must be a little wider than its text, or AppKit truncates it.
    private static let slack: CGFloat = 4
}

/// A label that is never vibrant, for secondary text whose contrast the theme sets.
///
/// Vibrant secondary text measured 2.4 to 3:1 over some backdrops, under glass rule 5's 3:1. Its
/// owner colours it from the resolved theme, as Core Text subtitles are. Vibrancy is decided here
/// at creation and never toggled, as glass rule 6 asks.
final class StaticLabel: FixedLabel {
    override var allowsVibrancy: Bool { false }
}

/// A wrapping label that is never vibrant, for the same reason as `StaticLabel`.
final class StaticWrappingLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}
