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
    /// A light editor window: a white page with lines of dark "text" drawn as rounded bars, a
    /// gutter and a few coloured marks. It stands in for a code or chat window behind the panel,
    /// with shapes instead of words. Not part of the default capture matrix.
    case document

    /// The backdrops glass rule 5 is checked over.
    public static let matrix: [BackdropKind] = [.busy, .white, .dark]
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
        case .document:
            drawDocument(in: bounds)
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

extension BackdropView {
    /// Lines of bars in a monospaced rhythm, from a fixed seed so every run draws the same page.
    fileprivate func drawDocument(in bounds: CGRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 96, height: bounds.height).fill()
        NSColor(red: 0.2, green: 0.35, blue: 0.85, alpha: 1).setFill()
        CGRect(x: 96, y: 0, width: 1, height: bounds.height).fill()
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let character: CGFloat = 8.4
        var y: CGFloat = 14
        while y < bounds.height {
            // A third of the lines are blank, as in prose with paragraphs or code with gaps.
            if next() > 0.3 {
                var x: CGFloat = 112 + CGFloat(Int(next() * 4)) * character * 2
                let end = min(bounds.width - 30, x + CGFloat(20 + Int(next() * 70)) * character)
                while x < end {
                    let word = CGFloat(2 + Int(next() * 8)) * character
                    let mark = next()
                    let color =
                        mark > 0.92
                        ? NSColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1)
                        : mark > 0.85
                            ? NSColor(red: 0.1, green: 0.5, blue: 0.25, alpha: 1) : NSColor(white: 0.12, alpha: 1)
                    color.setFill()
                    NSBezierPath(
                        roundedRect: CGRect(x: x, y: y + 4, width: min(word, end - x), height: 9), xRadius: 2,
                        yRadius: 2
                    ).fill()
                    x += word + character
                }
            }
            if next() > 0.8 {
                NSColor(white: 0.55, alpha: 1).setFill()
                NSBezierPath(
                    roundedRect: CGRect(x: 30, y: y + 5, width: 40, height: 7), xRadius: 2, yRadius: 2
                ).fill()
            }
            y += 19
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
