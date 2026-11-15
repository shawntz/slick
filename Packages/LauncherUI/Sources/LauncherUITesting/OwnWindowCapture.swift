import AppKit
@preconcurrency import ScreenCaptureKit

/// Captures this process's own windows with ScreenCaptureKit.
///
/// `SCShareableContent.currentProcess` needs no Screen Recording permission and renders real
/// glass: the material, its rim, its shadow and the key and non-key looks. Only this process's
/// windows are composited, so put a `BackdropWindow` behind the panel.
public enum OwnWindowCapture {
    public enum Failure: Error { case noDisplay, noWindows }

    /// A still image of `screenRect` (AppKit screen coordinates) at the display's pixel scale.
    public static func capture(_ screenRect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let display = display(containing: screenRect, in: content) else { throw Failure.noDisplay }
        guard !content.windows.isEmpty else { throw Failure.noWindows }
        let filter = SCContentFilter(display: display, including: content.windows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect(screenRect, display: display)
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(screenRect.width * scale)
        configuration.height = Int(screenRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The display under `screenRect`, from a shareable-content snapshot.
    static func display(containing screenRect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: screenRect.midX, y: primaryHeight - screenRect.midY)
        return content.displays.first { $0.frame.contains(topLeft) } ?? content.displays.first
    }

    /// `screenRect` in a display's own top-left coordinates, as ScreenCaptureKit wants it.
    static func sourceRect(_ screenRect: CGRect, display: SCDisplay) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: screenRect.minX - display.frame.minX,
            y: primaryHeight - screenRect.maxY - display.frame.minY,
            width: screenRect.width, height: screenRect.height
        )
    }
}
