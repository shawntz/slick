import CoreGraphics
import Foundation
import ImageIO
import Kit
import KitHosting
import Synchronization

/// The apps whose icons go into the atlas.
nonisolated public protocol AppIconSource: Sendable {
    /// Every app with its location and a stamp that changes when its icon may have. May read the
    /// disk; called off the main thread.
    func appIconEntries() -> [AppIconEntry]

    /// Where an app that is not in the list is installed, for an icon of its own. May ask
    /// LaunchServices; called off the main thread.
    func location(of bundleID: String) -> URL?

    /// Sent when the list may have changed.
    var changes: ChangeSignal { get }
}

/// The live app list: the ``ApplicationCatalog``, stamped with each app's `Info.plist` date. An app
/// the read guard keeps the loader from, such as one running from the Downloads folder, is left
/// out, so building the atlas never reads there.
nonisolated public struct CatalogAppIcons: AppIconSource {
    public let catalog: ApplicationCatalog
    private let locate: @Sendable (String) -> URL?
    private let readGuard: ReadGuard

    public init(
        catalog: ApplicationCatalog, locate: @escaping @Sendable (String) -> URL? = { _ in nil },
        readGuard: ReadGuard = .anywhere
    ) {
        self.catalog = catalog
        self.locate = locate
        self.readGuard = readGuard
    }

    public var changes: ChangeSignal {
        catalog.changes
    }

    public func appIconEntries() -> [AppIconEntry] {
        catalog.applications.values.compactMap { app in
            guard let url = app.url, readGuard.mayRead(url) else { return nil }
            let plist = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
            let date = (try? plist.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let seconds = date.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            return AppIconEntry(
                bundleID: app.bundleID, url: url, stamp: url.path(percentEncoded: false) + "@" + seconds)
        }
    }

    public func location(of bundleID: String) -> URL? {
        catalog.application(bundleID: bundleID)?.url ?? locate(bundleID)
    }
}

/// A fixed app list, for tests and for run environments other than `live`.
nonisolated public final class StaticAppIcons: AppIconSource {
    private let entries: Mutex<[AppIconEntry]>
    public let changes = ChangeSignal()

    public init(_ entries: [AppIconEntry] = []) {
        self.entries = Mutex(entries)
    }

    /// Replaces the list and sends ``changes``.
    public func set(_ entries: [AppIconEntry]) {
        self.entries.withLock { $0 = entries }
        changes.send()
    }

    public func appIconEntries() -> [AppIconEntry] {
        entries.withLock { $0 }
    }

    public func location(of bundleID: String) -> URL? {
        entries.withLock { $0.first { $0.bundleID == bundleID }?.url }
    }
}

/// The folder of website icons that features fill. A favicon is any image file named after its
/// domain, as ``normalizedDomain(_:)`` gives it, with any extension: `example.com.png`.
nonisolated public final class FaviconFolder: Sendable {
    public let folder: URL
    /// The files by domain, read when first needed and again after ``invalidate()``.
    private let index = Mutex<[String: URL]?>(nil)

    public init(folder: URL) {
        self.folder = folder
    }

    /// The domain as favicon files are named: lowercased, without "www." and a trailing dot.
    public static func normalizedDomain(_ domain: String) -> String {
        var name = domain.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".") { name.removeLast() }
        if name.hasPrefix("www.") { name.removeFirst(4) }
        return name
    }

    /// The cached icon file of the domain, or nil when none is cached. Lists the folder on first
    /// use; call it off the main thread.
    public func file(for domain: String) -> URL? {
        let key = Self.normalizedDomain(domain)
        if let known = index.withLock({ $0 }) { return known[key] }
        let listed = list()
        index.withLock { $0 = listed }
        return listed[key]
    }

    /// Forgets the listing, after the folder changed.
    public func invalidate() {
        index.withLock { $0 = nil }
    }

    private func list() -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        var files: [String: URL] = [:]
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            let domain = Self.normalizedDomain(url.deletingPathExtension().lastPathComponent)
            if files[domain] == nil { files[domain] = url }
        }
        return files
    }
}

/// Images at `https` URLs, downloaded once through the HTTP service and kept on disk. Nothing is
/// downloaded while the `fetchRemoteIcons` setting is off; an image already on disk is still used.
/// A failed download is not tried again until ``forgetFailures()``.
nonisolated public final class RemoteImageStore: Sendable {
    /// The largest image accepted.
    public static let maximumBytes = 4 << 20

    public let folder: URL
    private let http: any HTTPService
    private let settings: any SettingsService
    private let inFlight = Mutex<[URL: Task<Data?, Never>]>([:])
    private let failed = Mutex<Set<URL>>([])

    public init(folder: URL, http: any HTTPService, settings: any SettingsService) {
        self.folder = folder
        self.http = http
        self.settings = settings
    }

    /// Where the image of a URL is kept on disk.
    public func cacheFile(for url: URL) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return folder.appending(path: String(hash, radix: 16) + ".image", directoryHint: .notDirectory)
    }

    /// True when the setting allows downloads.
    public var mayFetch: Bool {
        HostSettings.settings(settings)[HostSettings.fetchRemoteIcons]
    }

    /// The image bytes of a URL: from disk, or downloaded once. Nil when the URL is not `https`,
    /// downloads are off, or the download failed or was not an image.
    public func data(for url: URL) async -> Data? {
        let file = cacheFile(for: url)
        if let data = try? Data(contentsOf: file) { return data }
        guard url.scheme?.lowercased() == "https", mayFetch, !failed.withLock({ $0.contains(url) }) else { return nil }
        let task = inFlight.withLock { tasks -> Task<Data?, Never> in
            if let running = tasks[url] { return running }
            let started = Task.detached(priority: .utility) { [self] in await download(url, to: file) }
            tasks[url] = started
            return started
        }
        let data = await task.value
        inFlight.withLock { _ = $0.removeValue(forKey: url) }
        return data
    }

    /// Lets failed URLs be tried again, such as after the setting was turned on.
    public func forgetFailures() {
        failed.withLock { $0.removeAll() }
    }

    private func download(_ url: URL, to file: URL) async -> Data? {
        do {
            let response = try await http.send(HTTPRequest(url, timeout: .seconds(15)))
            guard (200..<300).contains(response.status), !response.body.isEmpty,
                response.body.count <= Self.maximumBytes,
                let source = CGImageSourceCreateWithData(response.body as CFData, nil),
                CGImageSourceGetCount(source) > 0
            else {
                failed.withLock { _ = $0.insert(url) }
                return nil
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? response.body.write(to: file, options: .atomic)
            return response.body
        } catch {
            failed.withLock { _ = $0.insert(url) }
            return nil
        }
    }
}
