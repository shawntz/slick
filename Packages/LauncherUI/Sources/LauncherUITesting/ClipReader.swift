@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import VideoToolbox

/// One still of a clip and when it shows.
nonisolated public struct ClipFrame: @unchecked Sendable {
    public let image: CGImage
    /// Seconds from the start of the clip.
    public let time: Double

    public init(image: CGImage, time: Double) {
        self.image = image
        self.time = time
    }
}

/// Reads a recorded clip back as stills at a steady rate, for making smaller copies: a GIF, or an
/// MP4 with a lower rate or size. Reading twice is cheap, so encoders that need two passes, such
/// as a GIF that picks its palette from every frame, read the file twice instead of holding it.
nonisolated public enum ClipReader {
    public enum Failure: Error {
        case noVideo
        case cannotRead(String)
    }

    /// The clip's length in seconds and its pixel size.
    public static func info(of url: URL) async throws -> (duration: Double, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        return (duration, Int(size.width), Int(size.height))
    }

    /// Calls `body` with one frame every `1 / frameRate` seconds from 0 to the clip's end: the
    /// frame on screen at that moment, scaled to `width` pixels wide when given, in sRGB.
    public static func read(
        _ url: URL, frameRate: Double, width: Int? = nil, _ body: (ClipFrame) throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.cannotRead(reader.error.map(String.init(describing:)) ?? "could not start")
        }
        let period = 1 / frameRate
        let count = max(1, Int((duration / period).rounded(.down)))
        var next = 0
        var held: CGImage?
        func emit(until time: Double) throws {
            guard let held else { return }
            while next < count, Double(next) * period < time - 0.0001 {
                try body(ClipFrame(image: held, time: Double(next) * period))
                next += 1
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = sample.imageBuffer else { continue }
            let time = sample.presentationTimeStamp.seconds
            try emit(until: time)
            held = scaled(pixels, width: width)
            if next >= count { break }
        }
        try emit(until: .infinity)
        reader.cancelReading()
    }

    /// A frame's pixels as an sRGB image, scaled to `width` with high-quality interpolation.
    static func scaled(_ pixels: CVPixelBuffer, width: Int?) -> CGImage? {
        var decoded: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &decoded)
        guard let decoded else { return nil }
        let targetWidth = width ?? decoded.width
        let targetHeight = Int((Double(decoded.height) * Double(targetWidth) / Double(decoded.width)).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: targetWidth * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Writes a smaller MP4 from `source`: a lower rate, a smaller width or a lower bit rate.
    /// Returns the number of frames written.
    @discardableResult
    public static func transcode(
        _ source: URL, to destination: URL, frameRate: Double, width: Int? = nil, bitRate: Int
    ) async throws -> Int {
        let info = try await info(of: source)
        let outWidth = (width ?? info.width) / 2 * 2
        let outHeight = Int((Double(info.height) * Double(outWidth) / Double(info.width)).rounded()) / 2 * 2
        let writer = try MP4ClipWriter(
            url: destination, width: outWidth, height: outHeight,
            settings: .init(frameRate: frameRate, bitRate: bitRate))
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil, nil,
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outWidth, kCVPixelBufferHeightKey as String: outHeight,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ] as CFDictionary, &pool)
        guard let pool else { throw Failure.cannotRead("no pixel buffer pool") }
        var last = 0.0
        try await read(source, frameRate: frameRate, width: outWidth) { frame in
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: outWidth, height: outHeight,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            context.draw(frame.image, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            // The writer must not get a frame while it is busy; give it a moment.
            var tries = 0
            while !writer.append(buffer, at: frame.time), tries < 200 {
                tries += 1
                usleep(2000)
            }
            last = frame.time
        }
        try await writer.finish(at: max(last, info.duration))
        return writer.frameCount
    }
}
