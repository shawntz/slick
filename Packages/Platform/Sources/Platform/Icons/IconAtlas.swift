import CoreGraphics
import Darwin
import Foundation
import Kit

/// One app in the atlas: its bundle ID, where it is installed, and a stamp that changes when its
/// icon may have changed.
nonisolated public struct AppIconEntry: Hashable, Sendable {
    public var bundleID: String
    public var url: URL?
    public var stamp: String

    public init(bundleID: String, url: URL?, stamp: String) {
        self.bundleID = bundleID
        self.url = url
        self.stamp = stamp
    }
}

/// App icons at one pixel size, read from a memory-mapped file of raw BGRA squares.
///
/// Each image's pixels stay in the mapped file: no copy and no decode. The images are made when
/// the atlas loads, off the main thread, so a lookup is a dictionary read. The file stays mapped
/// while any image from it is alive. A rebuild writes a new file and swaps the index, so a mapped
/// file is never changed under a reader.
nonisolated public final class IconAtlas: Sendable {
    /// The side of every image in pixels.
    public let pixels: Int
    /// The image of each app, by bundle ID.
    public let images: [String: CGImage]
    /// The stamp each app had when its icon was drawn.
    public let stamps: [String: String]
    /// The data file, under the folder the atlas lives in.
    public let dataFile: URL
    private let file: MappedFile
    private let slots: [String: Int]

    private init(pixels: Int, file: MappedFile, dataFile: URL, slots: [String: Int], stamps: [String: String]) {
        self.pixels = pixels
        self.file = file
        self.dataFile = dataFile
        self.slots = slots
        self.stamps = stamps
        let slotBytes = Bitmap.byteCount(pixels: pixels)
        var images: [String: CGImage] = [:]
        images.reserveCapacity(slots.count)
        for (bundleID, slot) in slots {
            if let image = file.image(at: slot * slotBytes, pixels: pixels) { images[bundleID] = image }
        }
        self.images = images
    }

    /// The number of apps.
    public var count: Int {
        images.count
    }

    /// The raw pixels of an app's slot, for a rebuild that keeps unchanged icons.
    func pixels(of bundleID: String) -> UnsafeRawPointer? {
        guard let slot = slots[bundleID] else { return nil }
        return file.pointer + slot * Bitmap.byteCount(pixels: pixels)
    }

    /// True when the atlas holds exactly these apps with these stamps.
    func matches(_ entries: [AppIconEntry]) -> Bool {
        entries.count == stamps.count && entries.allSatisfy { stamps[$0.bundleID] == $0.stamp }
    }

    // MARK: Files

    /// What the index file records.
    struct Index: Codable {
        static let currentVersion = 1

        var version: Int
        var pixels: Int
        var dataFile: String
        var entries: [Entry]

        struct Entry: Codable {
            var id: String
            var slot: Int
            var stamp: String
        }
    }

    /// The index file of the atlas at a pixel size.
    static func indexURL(in folder: URL, pixels: Int) -> URL {
        folder.appending(path: "apps-\(pixels).json", directoryHint: .notDirectory)
    }

    /// Loads the atlas saved at this pixel size, or nil when there is none or it does not check
    /// out. Reads the disk; call it off the main thread.
    public static func load(from folder: URL, pixels: Int) -> IconAtlas? {
        guard let data = try? Data(contentsOf: indexURL(in: folder, pixels: pixels)),
            let index = try? JSONDecoder().decode(Index.self, from: data),
            index.version == Index.currentVersion, index.pixels == pixels,
            !index.dataFile.contains("/")
        else { return nil }
        let dataFile = folder.appending(path: index.dataFile, directoryHint: .notDirectory)
        let slotBytes = Bitmap.byteCount(pixels: pixels)
        let slotCount = (index.entries.map(\.slot).max() ?? -1) + 1
        guard let file = MappedFile(url: dataFile), file.length >= slotCount * slotBytes,
            index.entries.allSatisfy({ $0.slot >= 0 })
        else { return nil }
        var slots: [String: Int] = [:]
        var stamps: [String: String] = [:]
        for entry in index.entries {
            slots[entry.id] = entry.slot
            stamps[entry.id] = entry.stamp
        }
        return IconAtlas(pixels: pixels, file: file, dataFile: dataFile, slots: slots, stamps: stamps)
    }

    /// Draws every app's icon into a new atlas file, keeps the pixels of apps whose stamp did not
    /// change since `previous`, saves it and maps it. Apps the renderer cannot draw are left out.
    /// Reads and writes the disk and draws on several threads; call it off the main thread.
    public static func build(
        _ entries: [AppIconEntry], pixels: Int, renderer: any IconRenderer, reusing previous: IconAtlas?,
        in folder: URL
    ) throws -> IconAtlas {
        let entries = entries.sorted { $0.bundleID < $1.bundleID }
        let slotBytes = Bitmap.byteCount(pixels: pixels)
        let total = max(1, entries.count * slotBytes)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: total)
        let drawn = UnsafeMutableBufferPointer<Bool>.allocate(capacity: max(1, entries.count))
        defer { drawn.deallocate() }
        drawn.initialize(repeating: false)

        let reusable = previous?.pixels == pixels ? previous : nil
        let shared = SendablePointers(buffer: buffer, drawn: drawn)
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            let entry = entries[index]
            let slot = shared.buffer + index * slotBytes
            if let reusable, reusable.stamps[entry.bundleID] == entry.stamp,
                let old = reusable.pixels(of: entry.bundleID)
            {
                slot.copyMemory(from: old, byteCount: slotBytes)
                shared.drawn[index] = true
            } else if let context = Bitmap.context(pixels: pixels, data: slot) {
                shared.drawn[index] = renderer.drawApplication(
                    bundleID: entry.bundleID, at: entry.url, in: context, pixels: pixels)
            }
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "apps-\(pixels)-\(UUID().uuidString).bgra"
        let dataFile = folder.appending(path: name, directoryHint: .notDirectory)
        try Data(bytesNoCopy: buffer, count: total, deallocator: .none).write(to: dataFile, options: .atomic)
        var index = Index(version: Index.currentVersion, pixels: pixels, dataFile: name, entries: [])
        for (slot, entry) in entries.enumerated() where drawn[slot] {
            index.entries.append(Index.Entry(id: entry.bundleID, slot: slot, stamp: entry.stamp))
        }
        try JSONEncoder().encode(index).write(to: indexURL(in: folder, pixels: pixels), options: .atomic)
        removeStaleDataFiles(in: folder, pixels: pixels, keeping: name)

        guard let atlas = load(from: folder, pixels: pixels) else { throw CocoaError(.fileReadCorruptFile) }
        return atlas
    }

    /// Deletes data files of this size that the index no longer names. A file still mapped stays
    /// readable until it is unmapped.
    private static func removeStaleDataFiles(in folder: URL, pixels: Int, keeping name: String) {
        let prefix = "apps-\(pixels)-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for other in names where other.hasPrefix(prefix) && other.hasSuffix(".bgra") && other != name {
            try? FileManager.default.removeItem(at: folder.appending(path: other, directoryHint: .notDirectory))
        }
    }
}

/// Pointers the atlas builder's threads write to, each thread its own slots.
nonisolated private struct SendablePointers: @unchecked Sendable {
    let buffer: UnsafeMutableRawPointer
    let drawn: UnsafeMutableBufferPointer<Bool>
}

/// A file mapped read-only into memory, unmapped when the last image made from it is released.
nonisolated final class MappedFile: @unchecked Sendable {
    let pointer: UnsafeRawPointer
    let length: Int

    init?(url: URL) {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_FILE | MAP_SHARED, descriptor, 0), mapped != MAP_FAILED
        else { return nil }
        pointer = UnsafeRawPointer(mapped)
        self.length = length
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: pointer), length)
    }

    /// An image over the square that starts at `offset`. It keeps this file mapped while it lives.
    func image(at offset: Int, pixels: Int) -> CGImage? {
        let bytes = Bitmap.byteCount(pixels: pixels)
        guard offset >= 0, offset + bytes <= length else { return nil }
        let retained = Unmanaged.passRetained(self)
        guard
            let provider = CGDataProvider(
                dataInfo: retained.toOpaque(), data: pointer + offset, size: bytes,
                releaseData: { info, _, _ in
                    if let info { Unmanaged<MappedFile>.fromOpaque(info).release() }
                })
        else {
            retained.release()
            return nil
        }
        return CGImage(
            width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
            space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.info), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
