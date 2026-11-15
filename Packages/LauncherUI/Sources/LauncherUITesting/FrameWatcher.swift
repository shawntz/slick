import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Watches this process's windows frame by frame with a ScreenCaptureKit stream and records, for
/// each displayed frame, when the window server showed it and the mean luminance of a few regions.
///
/// Display times are mach ticks on the same clock as `LatencyClock`, so they subtract directly
/// from a handler timestamp to give "when did this reach the glass".
nonisolated public final class FrameWatcher: NSObject, SCStreamOutput, @unchecked Sendable {
    /// One displayed frame.
    public struct Frame: Sendable {
        /// When the window server displayed it, in mach ticks.
        public let displayTime: UInt64
        /// Mean luminance from 0 to 1 of each watched region, in the order given to `start`.
        public let luminance: [Double]
    }

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var regions: [CGRect] = []
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "FrameWatcher", qos: .userInteractive)

    /// Starts watching `screenRect` (AppKit screen coordinates). `regions` are rectangles inside
    /// it, in points from its top-left corner.
    @MainActor
    public func start(screenRect: CGRect, regions: [CGRect]) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let display = OwnWindowCapture.display(containing: screenRect, in: content) else {
            throw OwnWindowCapture.Failure.noDisplay
        }
        let filter = SCContentFilter(display: display, including: content.windows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = OwnWindowCapture.sourceRect(screenRect, display: display)
        // One pixel per point is plenty for mean luminance.
        configuration.width = max(16, Int(screenRect.width))
        configuration.height = max(16, Int(screenRect.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        lock.withLock {
            self.regions = regions
            frames.removeAll()
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    public func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    /// Every frame recorded so far.
    public func snapshot() -> [Frame] { lock.withLock { frames } }

    public func clear() { lock.withLock { frames.removeAll(keepingCapacity: true) } }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
            let pixels = buffer.imageBuffer
        else { return }
        let displayTime = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let regions = lock.withLock { self.regions }
        let luminance = regions.map { region -> Double in
            let minX = max(0, Int(region.minX))
            let maxX = min(width, Int(region.maxX))
            let minY = max(0, Int(region.minY))
            let maxY = min(height, Int(region.maxY))
            guard maxX > minX, maxY > minY else { return .nan }
            var sum = 0.0
            for y in minY..<maxY {
                let row = bytes + y * rowBytes
                for x in minX..<maxX {
                    let pixel = row + x * 4
                    sum += 0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])
                }
            }
            return sum / Double((maxX - minX) * (maxY - minY)) / 255
        }
        lock.withLock { frames.append(Frame(displayTime: displayTime, luminance: luminance)) }
    }
}
