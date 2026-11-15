import AppKit

/// A busy backdrop shown behind the panel during a scenario capture, so the glass has something
/// to refract: saturated diagonal stripes and black and white discs. It never takes key status and
/// lets clicks through. LauncherUITesting has a fuller one; the app draws its own so the release
/// binary does not link test support and the video frameworks it needs.
final class ScenarioBackdrop: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hasShadow = false
        level = .floating
        contentView = BackdropView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class BackdropView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let colors: [NSColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                .systemPurple, .white,
            ]
            let stripe: CGFloat = 36
            let span = bounds.width + bounds.height
            var index = 0
            var x = -bounds.height
            while x < span {
                colors[index % colors.count].setFill()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x, y: 0))
                path.line(to: CGPoint(x: x + stripe, y: 0))
                path.line(to: CGPoint(x: x + stripe + bounds.height, y: bounds.height))
                path.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
                path.close()
                path.fill()
                x += stripe
                index += 1
            }
            for (offset, color) in [(0.1, NSColor.black), (0.35, .white), (0.6, .black), (0.85, .white)] {
                color.setFill()
                let size = bounds.height * 0.18
                let center = CGPoint(x: bounds.width * offset, y: bounds.height * (1 - offset))
                NSBezierPath(
                    ovalIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                ).fill()
            }
        }
    }
}
