import AppKit

/// A shortcut drawn as small rounded capsules, one per key: `["⌘", "K"]`.
///
/// The key glyphs are vibrant labels, so they pick up the glass like the rest of the action bar.
public final class KeycapView: NSView {
    public var keys: [String] = [] {
        didSet { if keys != oldValue { rebuild() } }
    }

    private var caps: [(fill: NSView, label: FixedLabel)] = []
    private var metrics = Theme.standard.actionBar
    private var font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private var fill = CGColor(gray: 0, alpha: 0.07)

    override public var isFlipped: Bool { true }

    public init(keys: [String] = []) {
        super.init(frame: .zero)
        self.keys = keys
        setAccessibilityElement(false)
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    public func apply(_ theme: ResolvedTheme) {
        metrics = theme.theme.actionBar
        font = theme.theme.fonts.actionBarKeycap.nsFont
        fill = theme.keycapFill
        rebuild()
    }

    /// The width the keycaps need.
    public var fittingWidth: CGFloat {
        caps.reduce(0) { $0 + capWidth($1.label) } + CGFloat(metrics.keycapSpacing) * CGFloat(max(0, caps.count - 1))
    }

    override public func layout() {
        super.layout()
        let height = CGFloat(metrics.keycapHeight)
        var x: CGFloat = 0
        for cap in caps {
            let width = capWidth(cap.label)
            cap.fill.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            let labelHeight = cap.label.lineHeight
            cap.label.frame = CGRect(x: 0, y: ((height - labelHeight) / 2).rounded(), width: width, height: labelHeight)
            x += width + CGFloat(metrics.keycapSpacing)
        }
    }

    private func capWidth(_ label: FixedLabel) -> CGFloat {
        max(CGFloat(metrics.keycapMinWidth), label.textWidth + CGFloat(metrics.keycapPadding) * 2)
    }

    private func rebuild() {
        for cap in caps { cap.fill.removeFromSuperview() }
        caps = keys.map { key in
            let fill = NSView()
            fill.wantsLayer = true
            fill.layer?.cornerCurve = .continuous
            fill.layer?.cornerRadius = CGFloat(metrics.keycapRadius)
            fill.layer?.backgroundColor = self.fill
            let label = FixedLabel()
            label.stringValue = key
            label.lineBreakMode = .byClipping
            label.font = font
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            fill.addSubview(label)
            addSubview(fill)
            return (fill, label)
        }
        needsLayout = true
    }
}
