import AppKit
import Foundation
import Testing

@testable import SlickApp

/// The backdrop behind a scenario capture has its picture before it orders in, so a capture never
/// shows the Mac's desktop through it. Checked on a backdrop that is made off every screen and never
/// ordered in.
@MainActor @Suite("Scenario backdrop", .timeLimit(.minutes(1)))
struct ScenarioBackdropTests {
    /// One pixel's red, green and blue, from the top-left corner of the image.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Moves the image so the asked pixel lands on the context's only one.
            context.draw(
                image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// True when the layer's contents are this very image.
    static func holds(_ layer: CALayer, _ image: CGImage) -> Bool {
        guard let contents = layer.contents else { return false }
        return (contents as AnyObject) === image
    }

    @Test func drawsItsPictureBeforeItOrdersIn() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: -20000, y: -20000, width: 400, height: 300)
        let backdrop = ScenarioBackdrop(frame: frame)
        defer { backdrop.close() }
        #expect(!backdrop.isVisible)
        let view = try #require(backdrop.contentView as? ScenarioBackdrop.BackdropView)
        let image = try #require(view.picture)
        let scale = backdrop.backingScaleFactor
        #expect(image.width == Int((400 * scale).rounded()))
        #expect(image.height == Int((300 * scale).rounded()))

        // The layer shows the picture already: nothing waits for a display pass.
        let layer = try #require(view.layer)
        let contents = try #require(layer.contents)
        #expect(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        #expect(Self.holds(layer, image))
        #expect(layer.contentsScale == scale)

        // Each disc's center has the disc's color.
        for (offset, color) in ScenarioBackdrop.BackdropView.discs {
            let x = Int(CGFloat(image.width) * offset)
            let y = Int(CGFloat(image.height) * offset)
            let found = try Self.pixel(image, x: x, y: y)
            let expected = color == .black ? 0 : 255
            #expect(abs(found.red - expected) <= 2 && abs(found.blue - expected) <= 2, "disc at \(offset): \(found)")
        }
        // Between the discs the stripes are saturated color, not grey.
        let stripe = try Self.pixel(image, x: Int(CGFloat(image.width) * 0.22), y: Int(CGFloat(image.height) * 0.9))
        let spread = max(stripe.red, stripe.green, stripe.blue) - min(stripe.red, stripe.green, stripe.blue)
        #expect(spread > 60, "a stripe: \(stripe)")

        // Displaying it again keeps the same picture.
        view.needsDisplay = true
        backdrop.displayIfNeeded()
        #expect(Self.holds(layer, image))
        #expect(!backdrop.isVisible, "nothing ordered it in")
    }
}
