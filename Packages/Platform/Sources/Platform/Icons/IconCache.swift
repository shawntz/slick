import CoreGraphics
import Foundation
import Kit
import KitHosting
import Synchronization
import UniformTypeIdentifiers

/// The live icon provider. The main thread only looks icons up; everything else runs off it.
///
/// - App icons at 32 and 64 pixels come from an ``IconAtlas`` per size: a memory-mapped file of
///   BGRA squares, built off the main thread the first time a size is asked for, loaded from disk
///   at the next launch, and rebuilt when the app list changes. An app that is not in the atlas,
///   and app icons larger than 64 pixels, are drawn one at a time into the memory cache.
/// - Symbols, glyphs, color swatches, file and file type icons, local images, favicons and remote
///   images are drawn off the main thread into a memory cache bounded by ``memoryLimit``. The
///   least recently used images leave first.
/// - A favicon comes only from the favicon folder that features fill. Until one is there the icon
///   is a generic globe; the folder is watched, so a new file shows up without a restart.
/// - A remote image is downloaded once through the HTTP service and kept on disk, never while the
///   `fetchRemoteIcons` setting is off. Until it arrives the lookup returns nil; when it cannot
///   arrive it is a generic photo symbol.
/// - When images that were not ready become ready, ``changes`` is sent once per batch.
@MainActor public final class IconCache: IconProvider {
    /// The pixel sizes that get an atlas.
    nonisolated public static let atlasSizes = [32, 64]

    /// Where the cache keeps its files.
    nonisolated public struct Folders: Sendable {
        public var atlas: URL
        public var favicons: URL
        public var remote: URL

        public init(atlas: URL, favicons: URL, remote: URL) {
            self.atlas = atlas
            self.favicons = favicons
            self.remote = remote
        }
    }

    public let changes = ChangeSignal()
    /// The most bytes of image the memory cache keeps. Atlas images do not count.
    public let memoryLimit: Int
    /// How long the app list must stay quiet before the atlas is rebuilt.
    public let rebuildDelay: Duration

    private let loader: IconLoader
    private let watcher: (any FileWatchService)?
    private let settings: any SettingsService
    private let inbox = Inbox()

    private var appImages: [[String: CGImage]] = Array(repeating: [:], count: IconCache.atlasSizes.count)
    private var atlases: [IconAtlas?] = Array(repeating: nil, count: IconCache.atlasSizes.count)
    private var atlasWanted = Array(repeating: false, count: IconCache.atlasSizes.count)
    private var atlasBuilding = Array(repeating: false, count: IconCache.atlasSizes.count)
    private var atlasDirty = Array(repeating: false, count: IconCache.atlasSizes.count)
    private var memory: [IconKey: CacheEntry] = [:]
    private var memoryBytes = 0
    private var tick: UInt64 = 0
    private var pending: Set<IconKey> = []
    private var failed: Set<IconKey> = []
    private var generation = 0
    private var watches: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - folders: Where the atlas, the favicons and downloaded images live.
    ///   - renderer: Draws app, file and file type icons.
    ///   - apps: The apps that go into the atlas.
    ///   - http: Downloads remote images.
    ///   - settings: Holds `fetchRemoteIcons`.
    ///   - watcher: Watches the favicon folder after ``start()``.
    ///   - readGuard: Where the loader may read files and app bundles on its own. Elsewhere a file
    ///     gets its type's icon, an app the generic app icon and an image a placeholder.
    public init(
        folders: Folders, renderer: any IconRenderer, apps: any AppIconSource, http: any HTTPService,
        settings: any SettingsService, watcher: (any FileWatchService)? = nil, memoryLimit: Int = 32 << 20,
        rebuildDelay: Duration = .seconds(2), readGuard: ReadGuard = .anywhere
    ) {
        loader = IconLoader(
            renderer: renderer, apps: apps, atlasFolder: folders.atlas,
            favicons: FaviconFolder(folder: folders.favicons),
            remote: RemoteImageStore(folder: folders.remote, http: http, settings: settings), readGuard: readGuard)
        self.watcher = watcher
        self.settings = settings
        self.memoryLimit = memoryLimit
        self.rebuildDelay = rebuildDelay
    }

    /// Ends the watches when the cache goes away without ``stop()``.
    isolated deinit {
        stop()
    }

    // MARK: IconProvider

    public func image(for icon: Icon, size: IconSize, isDark: Bool) -> CGImage? {
        let icon = Self.resolve(icon, isDark: isDark)
        var pixels = max(1, size.pixels)
        if case .app(let bundleID) = icon, let bucket = Self.bucket(for: pixels) {
            if let image = appImages[bucket][bundleID] { return image }
            if !atlasWanted[bucket] { wantAtlas(bucket) }
            pixels = Self.atlasSizes[bucket]
        }
        let key = IconKey(icon: icon, pixels: pixels, isDark: isDark && Self.dependsOnAppearance(icon))
        if let entry = memory[key] {
            tick &+= 1
            entry.lastUse = tick
            return entry.image
        }
        request(key)
        return nil
    }

    public func prepare(_ icons: [Icon], size: IconSize) {
        for icon in icons {
            for isDark in Self.dependsOnAppearance(icon) ? [false, true] : [false] {
                _ = image(for: icon, size: size, isDark: isDark)
            }
        }
    }

    // MARK: Life cycle

    /// Loads the atlases saved at the last launch, rebuilds them when the app list changes,
    /// watches the favicon folder and follows the `fetchRemoteIcons` setting. Call it once.
    public func start() {
        guard watches.isEmpty else { return }
        let loader = loader
        watches.append(
            Task { [weak self] in
                let saved = await loader.savedAtlasSizes()
                for pixels in saved {
                    guard let self, let bucket = Self.atlasSizes.firstIndex(of: pixels) else { continue }
                    if !self.atlasWanted[bucket] { self.wantAtlas(bucket) }
                }
            })
        let appChanges = loader.apps.changes.stream()
        let delay = rebuildDelay
        watches.append(
            Task { [weak self] in
                for await _ in appChanges {
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    for bucket in Self.atlasSizes.indices where self.atlasWanted[bucket] {
                        self.rebuildAtlas(bucket)
                    }
                }
            })
        if let watcher {
            let favicons = loader.favicons
            watches.append(
                Task { [weak self] in
                    await loader.createFaviconFolder()
                    for await _ in watcher.watch([favicons.folder]) {
                        favicons.invalidate()
                        self?.invalidate { if case .favicon = $0 { true } else { false } }
                    }
                })
        }
        let remoteSetting = HostSettings.settings(settings).changes(of: HostSettings.fetchRemoteIcons)
        watches.append(
            Task { [weak self] in
                for await _ in remoteSetting {
                    loader.remote.forgetFailures()
                    self?.invalidate { if case .remote = $0 { true } else { false } }
                }
            })
    }

    /// Stops watching. Lookups keep working from what is cached.
    public func stop() {
        for watch in watches {
            watch.cancel()
        }
        watches = []
    }

    // MARK: Inspection

    /// The atlas at a pixel size, once it is installed.
    public func atlas(pixels: Int) -> IconAtlas? {
        Self.atlasSizes.firstIndex(of: pixels).flatMap { atlases[$0] }
    }

    /// The bytes the memory cache holds now.
    public var memoryCacheBytes: Int {
        memoryBytes
    }

    /// How many images the memory cache holds now.
    public var memoryCacheCount: Int {
        memory.count
    }

    /// True while icons are loading.
    public var isLoading: Bool {
        !pending.isEmpty || atlasBuilding.contains(true)
    }

    // MARK: Loading

    private func request(_ key: IconKey) {
        guard !pending.contains(key), !failed.contains(key) else { return }
        pending.insert(key)
        let generation = generation
        let inbox = inbox
        loader.load(key) { [weak self] image in
            inbox.add(Inbox.Result(key: key, image: image, generation: generation)) {
                self?.flush()
            }
        }
    }

    /// Takes every finished load at once and tells listeners once.
    private func flush() {
        let results = inbox.take()
        guard !results.isEmpty else { return }
        for result in results {
            pending.remove(result.key)
            guard result.generation == generation else { continue }
            if let image = result.image {
                insert(image, for: result.key)
            } else {
                failed.insert(result.key)
            }
        }
        evictIfNeeded()
        changes.send()
    }

    private func insert(_ image: CGImage, for key: IconKey) {
        let bytes = image.bytesPerRow * image.height
        if let old = memory[key] { memoryBytes -= old.bytes }
        tick &+= 1
        memory[key] = CacheEntry(image: image, bytes: bytes, lastUse: tick)
        memoryBytes += bytes
    }

    private func evictIfNeeded() {
        guard memoryBytes > memoryLimit else { return }
        let target = memoryLimit / 4 * 3
        for (key, entry) in memory.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard memoryBytes > target else { break }
            memory.removeValue(forKey: key)
            memoryBytes -= entry.bytes
        }
    }

    /// Drops cached images of the icons that match, so the next lookup loads them again.
    private func invalidate(_ matches: (Icon) -> Bool) {
        generation += 1
        for (key, entry) in memory where matches(key.icon) {
            memory.removeValue(forKey: key)
            memoryBytes -= entry.bytes
        }
        failed = failed.filter { !matches($0.icon) }
        pending.removeAll()
        changes.send()
    }

    // MARK: Atlases

    private func wantAtlas(_ bucket: Int) {
        atlasWanted[bucket] = true
        rebuildAtlas(bucket)
    }

    private func rebuildAtlas(_ bucket: Int) {
        guard !atlasBuilding[bucket] else {
            atlasDirty[bucket] = true
            return
        }
        atlasBuilding[bucket] = true
        let previous = atlases[bucket]
        let pixels = Self.atlasSizes[bucket]
        let loader = loader
        Task { [weak self] in
            let atlas = await loader.atlas(pixels: pixels, previous: previous)
            self?.install(atlas, bucket: bucket)
        }
    }

    private func install(_ atlas: IconAtlas?, bucket: Int) {
        atlasBuilding[bucket] = false
        if let atlas, atlas !== atlases[bucket] {
            atlases[bucket] = atlas
            appImages[bucket] = atlas.images
            let pixels = Self.atlasSizes[bucket]
            for (key, entry) in memory where key.pixels == pixels && atlas.images[key.bundleID ?? ""] != nil {
                memory.removeValue(forKey: key)
                memoryBytes -= entry.bytes
            }
            changes.send()
        }
        if atlasDirty[bucket] {
            atlasDirty[bucket] = false
            rebuildAtlas(bucket)
        }
    }

    // MARK: Rules

    /// The icon to draw in the appearance: adaptive icons resolve to their light or dark side.
    nonisolated static func resolve(_ icon: Icon, isDark: Bool) -> Icon {
        var icon = icon
        while case .adaptive(let light, let dark) = icon {
            icon = isDark ? dark : light
        }
        return icon
    }

    /// The atlas a pixel size uses, or nil when it is larger than every atlas.
    nonisolated static func bucket(for pixels: Int) -> Int? {
        atlasSizes.firstIndex { pixels <= $0 }
    }

    /// True when the icon looks different in dark appearance.
    nonisolated static func dependsOnAppearance(_ icon: Icon) -> Bool {
        switch icon {
        case .symbol(_, let tint):
            if case .rgba? = tint { false } else { true }
        case .color(.semantic): true
        case .adaptive: true
        default: false
        }
    }
}

/// One image the memory cache holds: an icon at a pixel size, in dark appearance when that matters.
nonisolated struct IconKey: Hashable, Sendable {
    var icon: Icon
    var pixels: Int
    var isDark: Bool

    /// The bundle ID of an app icon.
    var bundleID: String? {
        if case .app(let bundleID) = icon { bundleID } else { nil }
    }
}

/// A cached image and when it was last looked up.
final class CacheEntry {
    let image: CGImage
    let bytes: Int
    var lastUse: UInt64

    init(image: CGImage, bytes: Int, lastUse: UInt64) {
        self.image = image
        self.bytes = bytes
        self.lastUse = lastUse
    }
}

/// Finished loads waiting for the main thread. The first one in a batch schedules a flush.
nonisolated final class Inbox: Sendable {
    struct Result: Sendable {
        var key: IconKey
        var image: CGImage?
        var generation: Int
    }

    private let state = Mutex<(results: [Result], isScheduled: Bool)>(([], false))

    func add(_ result: Result, flush: @escaping @MainActor @Sendable () -> Void) {
        let schedule = state.withLock { state -> Bool in
            state.results.append(result)
            defer { state.isScheduled = true }
            return !state.isScheduled
        }
        if schedule {
            DispatchQueue.main.async { MainActor.assumeIsolated(flush) }
        }
    }

    func take() -> [Result] {
        state.withLock { state in
            defer { state = ([], false) }
            return state.results
        }
    }
}

/// Loads icons off the main thread: at most four drawings at once, downloads as tasks.
nonisolated final class IconLoader: Sendable {
    let renderer: any IconRenderer
    let apps: any AppIconSource
    let atlasFolder: URL
    let favicons: FaviconFolder
    let remote: RemoteImageStore
    let readGuard: ReadGuard
    private let queue: OperationQueue

    init(
        renderer: any IconRenderer, apps: any AppIconSource, atlasFolder: URL, favicons: FaviconFolder,
        remote: RemoteImageStore, readGuard: ReadGuard = .anywhere
    ) {
        self.renderer = renderer
        self.apps = apps
        self.atlasFolder = atlasFolder
        self.favicons = favicons
        self.remote = remote
        self.readGuard = readGuard
        queue = OperationQueue()
        queue.name = "platform.icons"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    func load(_ key: IconKey, completion: @escaping @Sendable (CGImage?) -> Void) {
        if case .remote(let url) = key.icon {
            Task.detached(priority: .utility) { [self] in
                completion(await remoteImage(url, pixels: key.pixels))
            }
            return
        }
        queue.addOperation { [self] in
            completion(render(key))
        }
    }

    /// Draws one icon. Called on the loader's queue.
    func render(_ key: IconKey) -> CGImage? {
        let pixels = key.pixels
        switch key.icon {
        case .symbol(let name, let tint):
            return IconDrawing.symbol(name, tint: tint, pixels: pixels, isDark: key.isDark)
        case .glyph(let text):
            return IconDrawing.glyph(text, pixels: pixels)
        case .color(let color):
            return IconDrawing.swatch(color, pixels: pixels, isDark: key.isDark)
        case .app(let bundleID):
            let location = apps.location(of: bundleID)
            if let location, !readGuard.mayRead(location) {
                return renderer.fileType(UTType.applicationBundle.identifier, pixels: pixels)
            }
            return Bitmap.image(pixels: pixels) { context in
                renderer.drawApplication(bundleID: bundleID, at: location, in: context, pixels: pixels)
            }
        case .file(let path):
            guard readGuard.mayRead(URL(filePath: path)) else {
                return renderer.fileType(Self.typeWithoutReading(path), pixels: pixels)
            }
            return renderer.file(at: path, pixels: pixels)
        case .fileType(let type):
            return renderer.fileType(type, pixels: pixels)
        case .image(let path):
            let url = URL(filePath: path)
            guard readGuard.mayRead(url) else { return placeholder("photo", pixels: pixels) }
            return IconDrawing.imageFile(at: url, pixels: pixels)
        case .favicon(let domain):
            if let file = favicons.file(for: domain), let image = IconDrawing.imageFile(at: file, pixels: pixels) {
                return image
            }
            return placeholder("globe", pixels: pixels)
        case .remote(let url):
            return placeholder(url.isFileURL ? "doc" : "photo", pixels: pixels)
        case .adaptive(let light, _):
            return render(IconKey(icon: light, pixels: pixels, isDark: key.isDark))
        }
    }

    /// The type whose icon stands for a file the loader may not read: its extension, an app bundle
    /// for ".app", and a folder for a path that ends in "/" or has no extension.
    static func typeWithoutReading(_ path: String) -> String {
        let url = URL(filePath: path)
        let pathExtension = url.pathExtension.lowercased()
        if path.hasSuffix("/") || pathExtension.isEmpty { return UTType.folder.identifier }
        if pathExtension == "app" { return UTType.applicationBundle.identifier }
        return pathExtension
    }

    @concurrent func remoteImage(_ url: URL, pixels: Int) async -> CGImage? {
        if let data = await remote.data(for: url), let image = IconDrawing.imageData(data, pixels: pixels) {
            return image
        }
        return placeholder("photo", pixels: pixels)
    }

    private func placeholder(_ symbol: String, pixels: Int) -> CGImage? {
        IconDrawing.symbol(symbol, tint: IconDrawing.placeholderGray, pixels: pixels, isDark: false)
    }

    /// The atlas at a pixel size for the current app list: the one given or the one on disk when
    /// it still matches, else a new one that reuses unchanged icons. Nil when there are no apps.
    @concurrent func atlas(pixels: Int, previous: IconAtlas?) async -> IconAtlas? {
        let entries = apps.appIconEntries()
        if let previous, previous.matches(entries) { return previous }
        let saved = previous == nil ? IconAtlas.load(from: atlasFolder, pixels: pixels) : nil
        if let saved, saved.matches(entries) { return saved }
        guard !entries.isEmpty else { return previous }
        return
            (try? IconAtlas.build(
                entries, pixels: pixels, renderer: renderer, reusing: previous ?? saved, in: atlasFolder))
            ?? previous
    }

    /// The pixel sizes with an atlas saved on disk.
    @concurrent func savedAtlasSizes() async -> [Int] {
        IconCache.atlasSizes.filter { pixels in
            FileManager.default.fileExists(
                atPath: IconAtlas.indexURL(in: atlasFolder, pixels: pixels).path(percentEncoded: false))
        }
    }

    @concurrent func createFaviconFolder() async {
        try? FileManager.default.createDirectory(at: favicons.folder, withIntermediateDirectories: true)
    }
}
