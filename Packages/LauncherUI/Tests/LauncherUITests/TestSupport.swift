import AppKit
import LauncherUITesting

@testable import LauncherUI

/// Helpers shared by the tests. Windows are placed far off every screen, so nothing appears on
/// the desktop and nothing takes key status.
enum TestSupport {
    static let offscreen = CGRect(x: -20000, y: -20000, width: 1600, height: 1000)

    static var lightTheme: ResolvedTheme {
        _ = NSApplication.shared
        return ResolvedTheme(
            theme: .standard, appearance: NSAppearance(named: .aqua)!, accessibility: DisplayAccessibility())
    }

    /// A result list in an ordered-in, off-screen window.
    static func makeList(theme: ResolvedTheme = lightTheme) -> (list: ResultListView, window: NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: Theme.standard.panel.width, height: Theme.standard.panel.maxContentHeight)
        let window = NSWindow(
            contentRect: CGRect(origin: offscreen.origin, size: frame.size), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = FlippedTestView(frame: frame)
        window.contentView = container
        let list = ResultListView(frame: frame)
        container.addSubview(list)
        list.apply(theme)
        window.orderFrontRegardless()
        return (list, window)
    }

    /// A surface placed off every screen and shown without key status.
    static func makeSurface() -> LauncherSurface {
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: offscreen)
        surface.panel.appearance = NSAppearance(named: .aqua)
        return surface
    }

    static func rows(_ titles: [String], idBase: UInt64 = 1) -> [ListRow] {
        titles.enumerated().map { index, title in
            ListRow(id: idBase + UInt64(index), title: title, subtitle: "Application")
        }
    }

    /// A 16-pixel opaque square.
    static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }
}

final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}
