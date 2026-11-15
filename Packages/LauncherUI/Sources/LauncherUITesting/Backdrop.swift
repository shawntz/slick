import AppKit

/// Synthetic content to put behind the panel in captures. No user content ever appears in one,
/// because captures include only this process's windows.
nonisolated public enum BackdropKind: String, Sendable, CaseIterable {
    /// Saturated stripes, black and white discs and large text: the hardest case for legibility.
    case busy
    /// A white document of black body text.
    case white
    /// A dark window with a lighter card.
    case dark
}

/// Draws a backdrop.
public final class BackdropView: NSView {
    public let kind: BackdropKind

    public init(kind: BackdropKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }

    override public func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        switch kind {
        case .busy:
            let colors: [NSColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple,
                .systemPink, .white,
            ]
            let stripe: CGFloat = 46
            var x = -bounds.height
            var index = 0
            while x < bounds.width {
                colors[index % colors.count].setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x + stripe, y: 0))
                path.line(to: NSPoint(x: x + stripe + bounds.height, y: bounds.height))
                path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
                path.close()
                path.fill()
                x += stripe
                index += 1
            }
            for disc in 0..<14 {
                let centerX = CGFloat((disc * 137) % max(1, Int(bounds.width)))
                let centerY = CGFloat((disc * 89) % max(1, Int(bounds.height)))
                (disc % 2 == 0 ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: centerX, y: centerY, width: 70, height: 70)).fill()
            }
            ("BUSY BACKGROUND 123" as NSString).draw(
                at: NSPoint(x: 40, y: 120),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 54), .foregroundColor: NSColor.black]
            )
            ("Lorem ipsum dolor sit" as NSString).draw(
                at: NSPoint(x: 80, y: 300),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.white]
            )
        case .white:
            NSColor.white.setFill()
            bounds.fill()
            let paragraph = String(
                repeating: "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. ",
                count: 3)
            var y: CGFloat = 30
            while y < bounds.height {
                (paragraph as NSString).draw(
                    in: NSRect(x: 40, y: y, width: bounds.width - 80, height: 18),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
                )
                y += 22
            }
        case .dark:
            NSColor(white: 0.07, alpha: 1).setFill()
            bounds.fill()
            NSColor(white: 0.18, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 320, height: 200), xRadius: 12, yRadius: 12).fill()
            ("Dark window content" as NSString).draw(
                at: NSPoint(x: 420, y: 200),
                withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
            )
        }
    }
}

/// A borderless window that shows a backdrop. Order it below the panel; close it right after
/// the capture so it is on screen only briefly.
public final class BackdropWindow: NSWindow {
    public init(kind: BackdropKind, frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        level = .floating
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = BackdropView(kind: kind)
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}
