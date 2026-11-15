import AppKit
import CoreGraphics
import Foundation
import Kit
import UniformTypeIdentifiers

/// Draws the icons that come from the system: apps, files and file types. ``LiveIconRenderer`` asks
/// `NSWorkspace`; ``SyntheticIconRenderer`` draws generated images, for tests and for run
/// environments other than `live`. Every call runs off the main thread.
nonisolated public protocol IconRenderer: Sendable {
    /// Draws an app's icon to fill a square context. False when there was nothing to draw.
    func drawApplication(bundleID: String, at url: URL?, in context: CGContext, pixels: Int) -> Bool

    /// The icon Finder shows for the file or folder at the path.
    func file(at path: String, pixels: Int) -> CGImage?

    /// The generic icon of a type identifier or file extension.
    func fileType(_ type: String, pixels: Int) -> CGImage?
}

/// The live renderer, on `NSWorkspace`. Drawing into a private context off the main thread is
/// safe, and `NSWorkspace` may wait on the icon service for tens of milliseconds, so it never runs
/// on the main thread.
nonisolated public struct LiveIconRenderer: IconRenderer {
    public init() {}

    public func drawApplication(bundleID: String, at url: URL?, in context: CGContext, pixels: Int) -> Bool {
        guard let url else { return false }
        draw(NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)), in: context, pixels: pixels)
        return true
    }

    public func file(at path: String, pixels: Int) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: path)
        return Bitmap.image(pixels: pixels) { context in
            draw(image, in: context, pixels: pixels)
            return true
        }
    }

    public func fileType(_ type: String, pixels: Int) -> CGImage? {
        let trimmed = type.hasPrefix(".") ? String(type.dropFirst()) : type
        guard let contentType = UTType(trimmed) ?? UTType(filenameExtension: trimmed) else { return nil }
        let image = NSWorkspace.shared.icon(for: contentType)
        return Bitmap.image(pixels: pixels) { context in
            draw(image, in: context, pixels: pixels)
            return true
        }
    }

    private func draw(_ image: NSImage, in context: CGContext, pixels: Int) {
        Bitmap.withAppKit(context) {
            image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }
}

/// A renderer that draws a rounded square in a color derived from the icon's key, for tests and
/// for run environments other than `live`, which must not show the user's apps or files. The
/// color of a key is stable across runs: ``color(for:)``.
nonisolated public struct SyntheticIconRenderer: IconRenderer {
    public init() {}

    public func drawApplication(bundleID: String, at url: URL?, in context: CGContext, pixels: Int) -> Bool {
        Self.drawSquare(key: "app:" + bundleID, in: context, pixels: pixels)
        return true
    }

    public func file(at path: String, pixels: Int) -> CGImage? {
        Bitmap.image(pixels: pixels) { context in
            Self.drawSquare(key: "file:" + path, in: context, pixels: pixels)
            return true
        }
    }

    public func fileType(_ type: String, pixels: Int) -> CGImage? {
        Bitmap.image(pixels: pixels) { context in
            Self.drawSquare(key: "type:" + type, in: context, pixels: pixels)
            return true
        }
    }

    /// The opaque color of a key's square, as 8-bit red, green and blue.
    public static func color(for key: String) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return (
            UInt8(truncatingIfNeeded: hash), UInt8(truncatingIfNeeded: hash >> 8), UInt8(truncatingIfNeeded: hash >> 16)
        )
    }

    static func drawSquare(key: String, in context: CGContext, pixels: Int) {
        let color = color(for: key)
        context.setFillColor(
            CGColor(
                srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255,
                alpha: 1))
        let side = CGFloat(pixels)
        let inset = side * 0.1
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.2, cornerHeight: side * 0.2, transform: nil))
        context.fillPath()
    }
}
