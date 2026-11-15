@preconcurrency import AVFoundation
import CoreVideo

/// Writes frames to an MP4 file with H.264 through AVFoundation, for clips that play in a
/// browser or a README.
///
/// Frames carry their own times, so a variable frame rate from `ClipRecorder` plays at the right
/// speed. A `frameRate` drops frames that come sooner than one period after the last one kept.
/// The file is tagged BT.709, which browsers treat as sRGB, and its index sits at the front so it
/// starts playing before it has downloaded.
nonisolated public final class MP4ClipWriter: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        /// The most frames per second to keep. Nil keeps every frame.
        public var frameRate: Double?
        /// Average bits per second.
        public var bitRate: Int
        /// The longest gap between key frames, in seconds.
        public var keyFrameInterval: Double

        public init(frameRate: Double? = nil, bitRate: Int = 8_000_000, keyFrameInterval: Double = 2) {
            self.frameRate = frameRate
            self.bitRate = bitRate
            self.keyFrameInterval = keyFrameInterval
        }
    }

    public enum Failure: Error { case cannotWrite(String) }

    public let url: URL
    public let width: Int
    public let height: Int
    public let settings: Settings

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var lastTime: Double?
    private var appended = 0

    /// Frames written so far.
    public var frameCount: Int { lock.withLock { appended } }

    /// A writer of `width` by `height` frames to `url`, replacing any file there. Both sizes must
    /// be even.
    public init(url: URL, width: Int, height: Int, settings: Settings = Settings()) throws {
        self.url = url
        self.width = width
        self.height = height
        self.settings = settings
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let expectedRate = settings.frameRate ?? 60
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalDurationKey: settings.keyFrameInterval,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoExpectedSourceFrameRateKey] = Int(expectedRate.rounded())
        let output: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw Failure.cannotWrite("the writer refused the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.cannotWrite(writer.error.map(String.init(describing:)) ?? "could not start")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends a frame shown at `time` seconds. Returns false when it was dropped: too soon after
    /// the last frame for the frame rate, not after it, or the encoder was busy.
    @discardableResult
    public func append(_ pixels: CVPixelBuffer, at time: Double) -> Bool {
        lock.withLock {
            if let lastTime {
                let period = settings.frameRate.map { 1 / $0 } ?? 0
                // A little slack, so frames on a 120 Hz clock are kept at 60 per second.
                guard time > lastTime, time - lastTime >= period * 0.9 else { return false }
            }
            guard input.isReadyForMoreMediaData,
                adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000))
            else { return false }
            lastTime = time
            appended += 1
            return true
        }
    }

    /// Ends the file at `end` seconds. The last frame is held until then, so a still ending lasts
    /// as long as it did on screen.
    public func finish(at end: Double? = nil) async throws {
        let sessionEnd: Double? = lock.withLock {
            guard let lastTime else { return nil }
            // Without an end, the last frame lasts one period, or a sixtieth of a second.
            let period = settings.frameRate.map { 1 / $0 } ?? 1.0 / 60
            return max(end ?? 0, lastTime + period)
        }
        input.markAsFinished()
        if let sessionEnd { writer.endSession(atSourceTime: CMTime(seconds: sessionEnd, preferredTimescale: 60_000)) }
        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure.cannotWrite(writer.error.map(String.init(describing:)) ?? "status \(writer.status.rawValue)")
        }
    }

    /// Stops and deletes the file.
    public func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
