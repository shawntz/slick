import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Records this process's own windows as a stream of frames through ScreenCaptureKit, for clips
/// of the launcher in motion.
///
/// Like `OwnWindowCapture`, it uses `SCShareableContent.currentProcess`, which needs no Screen
/// Recording permission and shows real glass. Only this process's windows appear, so put a
/// backdrop window behind the panel. Frames come at the display's refresh rate or a set rate, in
/// sRGB, at the display's pixel scale. The window server sends a frame only when something
/// changed, so a still moment gives no frames; encoders hold the last frame across the gap.
///
/// It knows nothing about the demo or the app: anything that shows windows can record them.
nonisolated public final class ClipRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// One frame and when it was shown.
    public struct Frame: @unchecked Sendable {
        /// BGRA pixels in sRGB. Valid only during the `onFrame` call; copy what you keep.
        public let pixels: CVPixelBuffer
        /// Seconds since the first frame, which is 0.
        public let time: Double
        /// When the window server displayed it, in mach ticks on `LatencyClock`'s clock, or 0 when
        /// the stream did not say.
        public var displayTime: UInt64 = 0
    }

    /// What one recording delivered.
    public struct Summary: Sendable, Equatable {
        /// Frames handed to `onFrame`.
        public var frames: Int
        /// Seconds from start to stop.
        public var duration: Double
        /// The rate the stream asked for, in frames per second.
        public var frameRate: Double
        /// Pixel size of every frame.
        public var width: Int
        public var height: Int
    }

    public enum Failure: Error {
        case noDisplay, notRecording
        case stream(String)
    }

    /// Frames per second to ask for. Nil asks for the display's refresh rate.
    public let frameRate: Double?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ClipRecorder", qos: .userInteractive)
    private var stream: SCStream?
    private var onFrame: (@Sendable (Frame) -> Void)?
    private var startTime: CMTime?
    private var started = Date()
    private var frames = 0
    private var size = (width: 0, height: 0)
    private var rate = 0.0
    private var failure: String?

    public init(frameRate: Double? = nil) {
        self.frameRate = frameRate
    }

    /// The pixel size frames of `screenRect` will have, at its display's scale.
    @MainActor
    public static func pixelSize(of screenRect: CGRect) -> (width: Int, height: Int) {
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        // H.264 wants even sizes.
        func even(_ value: CGFloat) -> Int { Int((value * scale).rounded()) / 2 * 2 }
        return (even(screenRect.width), even(screenRect.height))
    }

    /// Starts recording `screenRect`, in AppKit screen coordinates. `onFrame` runs on a private
    /// queue for every frame that shows new content.
    @MainActor
    public func start(screenRect: CGRect, onFrame: @escaping @Sendable (Frame) -> Void) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let display = OwnWindowCapture.display(containing: screenRect, in: content) else {
            throw Failure.noDisplay
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let refresh = Double(screen?.maximumFramesPerSecond ?? 60)
        let rate = frameRate ?? refresh
        let pixels = Self.pixelSize(of: screenRect)
        let filter = SCContentFilter(display: display, including: content.windows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = OwnWindowCapture.sourceRect(screenRect, display: display)
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.minimumFrameInterval = CMTime(seconds: 1 / rate, preferredTimescale: 600_000)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        lock.withLock {
            self.onFrame = onFrame
            startTime = nil
            frames = 0
            size = pixels
            self.rate = rate
            failure = nil
            started = Date()
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops recording. Every `onFrame` call has returned when this returns.
    @MainActor
    public func stop() async throws -> Summary {
        guard let stream else { throw Failure.notRecording }
        self.stream = nil
        try? await stream.stopCapture()
        // Let a frame that was being handed over finish.
        queue.sync {}
        return try lock.withLock {
            onFrame = nil
            if let failure { throw Failure.stream(failure) }
            return Summary(
                frames: frames, duration: Date().timeIntervalSince(started), frameRate: rate, width: size.width,
                height: size.height)
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
            let pixels = buffer.imageBuffer
        else { return }
        let presentation = buffer.presentationTimeStamp
        let displayTime = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let handler: (@Sendable (Frame) -> Void)? = lock.withLock {
            guard let onFrame else { return nil }
            if startTime == nil { startTime = presentation }
            frames += 1
            return onFrame
        }
        guard let handler, let startTime = lock.withLock({ startTime }) else { return }
        handler(Frame(pixels: pixels, time: max(0, (presentation - startTime).seconds), displayTime: displayTime))
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { failure = String(describing: error) }
    }
}
