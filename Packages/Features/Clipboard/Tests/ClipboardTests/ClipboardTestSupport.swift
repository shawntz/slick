import CoreGraphics
import Foundation
import ImageIO
import Kit
import KitTesting
import Synchronization
import UniformTypeIdentifiers

@testable import Clipboard

/// A harness over the feature with the fakes, plus shortcuts for playing copies. Every app, text and
/// path here is synthetic.
@MainActor
struct ClipboardHarness {
    static let editor = "com.example.editor"
    static let browser = "com.example.browser"

    let harness: FeatureHarness<ClipboardHistoryFeature>

    var feature: ClipboardHistoryFeature { harness.feature }
    var fakes: FakeServices { harness.fakes }
    var pasteboard: FakePasteboard { harness.fakes.pasteboard }
    var store: HistoryStore { harness.feature.store }
    var settings: FeatureSettings { harness.context.settings }

    /// Makes the feature over fresh fakes and activates it.
    init(fakes: FakeServices = FakeServices(), activate: Bool = true) async {
        fakes.workspace.installed = [
            AppInfo(bundleID: Self.editor, name: "Example Editor"),
            AppInfo(bundleID: Self.browser, name: "Example Browser"),
        ]
        harness = FeatureHarness(ClipboardHistoryFeature.self, fakes: fakes)
        if activate {
            await harness.activate()
            await harness.feature.startupPrune?.value
        }
    }

    /// Plays another app copying plain text and waits until the monitor has handled it.
    @discardableResult
    func copy(_ text: String, from app: String? = editor) async throws -> PasteboardEntry {
        let entry = pasteboard.simulateCopy(text, from: app)
        try await harness.settle()
        return entry
    }

    /// Plays another app copying several representations and waits until the monitor has handled it.
    @discardableResult
    func copy(_ contents: [PasteboardContent], from app: String? = editor) async throws -> PasteboardEntry {
        let entry = pasteboard.simulateCopy(contents, from: app)
        try await harness.settle()
        return entry
    }

    /// Moves the fake clock forward.
    func advance(minutes: Double) {
        fakes.clock.advance(by: .seconds(minutes * 60))
    }

    /// Opens the history page.
    func openHistory() async throws {
        try await harness.run("history")
    }

    /// The keys in the store, newest first.
    func keys() async throws -> [ItemKey] {
        try await store.keys()
    }

    /// The row ID for text the history holds.
    static func id(ofText text: String) -> ItemID {
        HistoryRows.id(textKey(text))
    }

    static func textKey(_ text: String) -> ItemKey {
        ItemKey(hashing: Data(("text\u{0}" + text).utf8))
    }

    /// Settings over the fakes, for setting values before the feature activates.
    static func settings(_ fakes: FakeServices) -> FeatureSettings {
        FeatureSettings(featureID: ClipboardHistoryFeature.manifest.id, service: fakes.settings)
    }
}

/// Synthetic content.
enum Samples {
    static let link = URL(string: "https://example.com/docs/page")!
    static let otherLink = URL(string: "https://example.org/start")!
    static let fileA = URL(filePath: "/tmp/clipboard-tests/notes-a.txt")
    static let fileB = URL(filePath: "/tmp/clipboard-tests/notes-b.txt")
    static let rtf = Data(#"{\rtf1\ansi {\b Bold} words}"#.utf8)

    /// A PNG of one color, made in memory.
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Bytes that claim to be a PNG but are not one, of a given size, for the storage cap.
    static func fakeImage(bytes: Int, seed: UInt8) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }
}

/// A store in a temporary folder. A test removes it with `defer { temporary.remove() }`: the
/// store creates its files on first use, which may come after the last use of this object.
final class TemporaryStore {
    let folder: URL
    let store: HistoryStore

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "clipboard-store-\(UUID().uuidString)")
        store = HistoryStore(folder: folder)
    }

    /// Deletes the folder and everything the store wrote in it.
    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func capture(_ text: String, source: String? = "com.example.editor") -> Capture {
        Capture(
            PasteboardEntry(contents: [.text(text)], sourceBundleID: source, date: .distantPast, changeCount: 0),
            maximumBytes: ClipboardSettings.maximumItemBytes)!
    }

    static func capture(_ contents: [PasteboardContent], source: String? = "com.example.editor") -> Capture? {
        Capture(
            PasteboardEntry(contents: contents, sourceBundleID: source, date: .distantPast, changeCount: 0),
            maximumBytes: ClipboardSettings.maximumItemBytes)
    }
}

/// A pasteboard that passes everything to a fake and counts reads, to prove the monitor never reads
/// the pasteboard itself.
final class CountingPasteboard: PasteboardService {
    let base: FakePasteboard
    private let reads = Atomic<Int>(0)

    init(base: FakePasteboard) {
        self.base = base
    }

    var readCount: Int { reads.load(ordering: .relaxed) }

    func copy(_ content: PasteboardContent, options: CopyOptions) async {
        await base.copy(content, options: options)
    }

    func paste(_ content: PasteboardContent, charactersAfterCursor: Int) async throws {
        try await base.paste(content, charactersAfterCursor: charactersAfterCursor)
    }

    func read() async -> PasteboardEntry? {
        reads.add(1, ordering: .relaxed)
        return await base.read()
    }

    func recentText(offset: Int) async -> String? {
        await base.recentText(offset: offset)
    }

    var changeCount: Int { base.changeCount }

    func entries() -> AsyncStream<PasteboardEntry> {
        base.entries()
    }
}
