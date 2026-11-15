import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures this process's own windows with ScreenCaptureKit, for scenario captures.
///
/// `SCShareableContent.currentProcess` lists only this app's windows and needs no Screen Recording
/// permission, so nothing prompts. Only this process's windows are composited: put a backdrop
/// window of your own behind the panel for a realistic look.
public enum PanelSnapshot {
    public enum Failure: Error { case noDisplay, noWindows, timedOut, cannotWrite }

    /// A still image of `screenRect`, in AppKit screen coordinates, at the display's pixel scale.
    public static func capture(_ screenRect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: screenRect.midX, y: primaryHeight - screenRect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first
        else { throw Failure.noDisplay }
        guard !content.windows.isEmpty else { throw Failure.noWindows }
        let filter = SCContentFilter(display: display, including: content.windows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: screenRect.minX - display.frame.minX, y: primaryHeight - screenRect.maxY - display.frame.minY,
            width: screenRect.width, height: screenRect.height)
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(screenRect.width * scale)
        configuration.height = Int(screenRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Writes an image as a PNG file, creating its folder.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.cannotWrite }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWrite }
    }
}

/// Key events made in this process and handed straight to a view, never posted to the system.
enum LocalKeyEvents {
    /// A key-down event, built from a `CGEvent` as real presses are. Creating a `CGEvent` needs no
    /// permission; only posting one would, and these are never posted.
    static func keyDown(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return nil }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        event.flags = flags
        let units = Array(characters.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return NSEvent(cgEvent: event)
    }
}
