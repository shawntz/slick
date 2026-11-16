import AppKit
import Foundation
import Kit
import KitHosting
import LauncherUI
import SwiftUI
import Testing

@testable import SettingsUI

/// A click on a theme tile selects the theme and moves the ring. The click is handed straight to
/// the view a window of the test's own finds under the pointer, as the window does with a click;
/// the window sits far off every display and is never ordered in, and nothing is posted to the
/// system. SwiftUI handles no event in a window that is not on screen, so only AppKit's part of a
/// click can run here, which is the part that failed: the preview is an AppKit view.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ThemeTileClickTests {
    static let width: CGFloat = 600
    static let height: CGFloat = 300

    /// The left edge and the middle of a tile's preview frame, in the view's top-down points.
    static func tileRing(_ index: Int) -> CGPoint {
        let columns = CGFloat(ThemeTiles.columns)
        let tileWidth = (width - ThemeTiles.spacing * (columns - 1)) / columns
        let column = CGFloat(index % ThemeTiles.columns)
        let x = column * (tileWidth + ThemeTiles.spacing)
        return CGPoint(x: x, y: ThemeTiles.previewHeight / 2)
    }

    @Test func clickingATileOnTheThemeStepSelectsItsThemeAndMovesTheRing() throws {
        let bed = TestBed()
        let context = bed.context()
        let model = OnboardingModel(context: context) {}
        #expect(model.selectedTheme == "Standard")
        let target = try #require(model.themes.dropFirst().first)
        let view = ThemeTiles(model: model)
            .frame(width: Self.width, height: Self.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = OffscreenWindow(view, size: CGSize(width: Self.width, height: Self.height))
        defer { window.close() }

        let ring = Self.tileRing(0)
        let next = Self.tileRing(1)
        let before = try #require(window.snapshot())
        // The middle of the second tile's preview, where the launcher picture is drawn.
        let point = CGPoint(x: next.x + 60, y: next.y)
        #expect(window.viewUnder(point) is ThemePreviewView)
        #expect(window.click(at: point))
        #expect(model.selectedTheme == target.name)
        #expect(bed.general[HostSettings.themeName] == target.name)
        let after = try #require(window.snapshot())
        // The ring left the first tile and drew around the second.
        #expect(OffscreenWindow.differs(before, after, at: CGPoint(x: ring.x + 1, y: ring.y)))
        #expect(OffscreenWindow.differs(before, after, at: CGPoint(x: next.x + 1, y: next.y)))
        // A click that ends outside the preview selects nothing.
        let third = Self.tileRing(2)
        #expect(window.click(at: CGPoint(x: third.x + 60, y: third.y), releasedAt: CGPoint(x: third.x + 60, y: 200)))
        #expect(model.selectedTheme == target.name)
    }

    @Test func thePreviewInTheAppearancePaneTakesNoClick() throws {
        let bed = TestBed()
        let context = bed.context()
        let appearance = AppearanceModel(context: context)
        let window = OffscreenWindow(
            AppearancePane(model: appearance).frame(width: 760, height: 900), size: CGSize(width: 760, height: 900))
        defer { window.close() }
        // The pane's preview is a picture: nothing under the pointer is it, so it can never take a
        // click meant for the theme picker below it.
        let preview = try #require(window.firstView(of: ThemePreviewView.self) { _ in true })
        #expect(preview.onClick == nil)
        let middle = preview.convert(CGPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: window.hosting)
        #expect(!(window.viewUnder(CGPoint(x: middle.x, y: window.size.height - middle.y)) is ThemePreviewView))
        // Choosing in the picker selects the theme, as the picker's binding does.
        appearance.select("Graphite")
        #expect(appearance.selectedName == "Graphite")
        #expect(bed.general[HostSettings.themeName] == "Graphite")
    }
}

/// A window of the test's own, far off every display and never ordered in, with a SwiftUI view.
@MainActor final class OffscreenWindow {
    let window: NSWindow
    let hosting: NSView
    let size: CGSize

    init<V: View>(_ view: V, size: CGSize) {
        _ = NSApplication.shared
        self.size = size
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        self.window = window
        self.hosting = hosting
        settle()
    }

    func close() {
        window.close()
    }

    /// Lets SwiftUI lay out and draw.
    func settle() {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// The view a click at a point, in top-down points, goes to, as the window finds it.
    func viewUnder(_ point: CGPoint) -> NSView? {
        hosting.hitTest(NSPoint(x: point.x, y: size.height - point.y))
    }

    /// Hands a left click straight to the view under the point, pressed there and released at
    /// `releasedAt`, as the window would. False when no view is under the point.
    @discardableResult
    func click(at point: CGPoint, releasedAt release: CGPoint? = nil) -> Bool {
        guard let target = viewUnder(point) else { return false }
        for (type, at) in [(NSEvent.EventType.leftMouseDown, point), (.leftMouseUp, release ?? point)] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: at.x, y: size.height - at.y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { return false }
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
        settle()
        return true
    }

    /// The view drawn into a bitmap at one pixel per point.
    func snapshot() -> NSBitmapImageRep? {
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// True when the two pictures differ clearly at a point in top-down points.
    static func differs(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep, at point: CGPoint) -> Bool {
        let scale = CGFloat(first.pixelsWide) / first.size.width
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            let b = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return false }
        let distance =
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        return distance > 0.3
    }

    /// The first view of a kind in the window that passes a check.
    func firstView<T: NSView>(of type: T.Type, where check: (T) -> Bool) -> T? {
        func search(_ view: NSView) -> T? {
            if let match = view as? T, check(match) { return match }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(hosting)
    }
}
