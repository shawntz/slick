import Foundation
import Kit

/// One bookmark ready to show, with everything its actions need.
nonisolated struct Bookmark: Hashable, Sendable {
    /// The row key: `<profile id>/<browser's id>`, unique in the snapshot and stable across launches
    /// while the browser keeps its ID.
    var key: String
    /// The title on one line, or one made from the link when the browser stored none.
    var title: String
    /// The link, cleaned as a browser reads it.
    var link: String
    var kind: LinkKind
    /// The link as a URL, for web links that Foundation can read. Parsed once, here.
    var webURL: URL?
    /// The host of a web link without `www.`.
    var host: String?
    var folders: [String]
    var browser: Browser
    var profileID: String
    var profileName: String
    var dateAdded: Date?
    var isReadingList: Bool
    var isOnBar: Bool
}

/// What a row carries, so its actions work after root search hands it back from a snapshot.
nonisolated struct BookmarkPayload: Codable, Hashable, Sendable {
    /// Nil when the link is too long to carry; the actions then need the bookmark loaded.
    var link: String?
    var title: String
    var browser: Browser
    var kind: LinkKind
}

/// A profile's bookmarks as one parse found them.
nonisolated struct ProfileBookmarks: Sendable {
    var profile: BrowserProfile
    var bookmarks: [ParsedBookmark]
}

/// A profile as the filter dropdown lists it.
nonisolated struct ProfileSummary: Hashable, Sendable {
    var browser: Browser
    var id: String
    var name: String
    var count: Int
    var readingListCount: Int
}

/// Every bookmark the feature shows, as rows built once off the main thread.
nonisolated struct BookmarkSnapshot: Sendable {
    var bookmarks: [Bookmark] = []
    /// The list's rows, in the same order as ``bookmarks``.
    var rows: [Row] = []
    /// Root search's rows: web, file and app links only, one per link, at most
    /// ``BookmarkIndex/catalogLimit``.
    var catalogRows: [Row] = []
    var profiles: [ProfileSummary] = []
    private var positions: [String: Int] = [:]

    static let empty = BookmarkSnapshot()

    init() {}

    init(bookmarks: [Bookmark], rows: [Row], catalogRows: [Row], profiles: [ProfileSummary]) {
        self.bookmarks = bookmarks
        self.rows = rows
        self.catalogRows = catalogRows
        self.profiles = profiles
        var positions: [String: Int] = [:]
        positions.reserveCapacity(bookmarks.count)
        for (index, bookmark) in bookmarks.enumerated() { positions[bookmark.key] = index }
        self.positions = positions
    }

    func bookmark(key: String) -> Bookmark? {
        positions[key].map { bookmarks[$0] }
    }

    /// The rows a filter option shows, in order. See ``BookmarkFilter``.
    func rows(matching filter: BookmarkFilter) -> [Row] {
        if filter == .all { return rows }
        return zip(bookmarks, rows).compactMap { filter.matches($0.0) ? $0.1 : nil }
    }
}

/// Builds a snapshot from what the parsers found.
nonisolated enum BookmarkIndex {
    static let namespace = "bookmarks"
    /// Root search holds at most this many bookmarks, so the catalog stays near the size the
    /// engine's budgets were measured at.
    static let catalogLimit = 5_000
    /// Titles longer than this are cut. The host truncates what it draws anyway.
    static let titleLimit = 300
    /// A link longer than this does not travel in the row's payload, which should stay under 1 KB.
    static let payloadLinkLimit = 800
    /// The subtitle keeps this many folders, the innermost ones.
    static let subtitleFolders = 6

    /// The rows for every profile, in browser order, then the profile's order. Exact repeats in one
    /// profile, the same link and title in the same folder, show once.
    static func build(_ profiles: [ProfileBookmarks], includesReadingList: Bool) -> BookmarkSnapshot {
        let ordered = profiles.sorted { left, right in
            let (a, b) = (left.profile.browser.order, right.profile.browser.order)
            return a != b ? a < b : left.profile.key.localizedStandardCompare(right.profile.key) == .orderedAscending
        }
        let profileCounts = Dictionary(grouping: ordered, by: \.profile.browser).mapValues(\.count)
        let total = ordered.reduce(0) { $0 + $1.bookmarks.count }
        var bookmarks: [Bookmark] = []
        var rows: [Row] = []
        bookmarks.reserveCapacity(total)
        rows.reserveCapacity(total)
        var summaries: [ProfileSummary] = []
        var usedKeys = Set<String>(minimumCapacity: total)
        for entry in ordered {
            let profile = entry.profile
            var seen = Set<Repeat>()
            var summary = ProfileSummary(
                browser: profile.browser, id: profile.id, name: profile.name, count: 0, readingListCount: 0)
            let showsProfile = (profileCounts[profile.browser] ?? 0) > 1
            for parsed in entry.bookmarks {
                if parsed.isReadingList && !includesReadingList { continue }
                let link = LinkKind.cleaned(parsed.url)
                guard !link.isEmpty, seen.insert(Repeat(parsed, link: link)).inserted else { continue }
                let bookmark = makeBookmark(
                    parsed, link: link, profile: profile, profileID: summary.id, profileName: summary.name,
                    usedKeys: &usedKeys)
                bookmarks.append(bookmark)
                rows.append(row(bookmark, showsProfile: showsProfile))
                summary.count += 1
                if bookmark.isReadingList { summary.readingListCount += 1 }
            }
            summaries.append(summary)
        }
        return BookmarkSnapshot(
            bookmarks: bookmarks, rows: rows, catalogRows: catalogRows(bookmarks, rows: rows), profiles: summaries)
    }

    /// What makes two entries of one profile the same bookmark.
    private struct Repeat: Hashable {
        var link: String
        var title: String
        var folders: [String]
        var isReadingList: Bool

        init(_ parsed: ParsedBookmark, link: String) {
            self.link = link
            self.title = parsed.title
            self.folders = parsed.folders
            self.isReadingList = parsed.isReadingList
        }
    }

    private static func makeBookmark(
        _ parsed: ParsedBookmark, link: String, profile: BrowserProfile, profileID: String, profileName: String,
        usedKeys: inout Set<String>
    ) -> Bookmark {
        let kind = LinkKind.of(link)
        let webURL = kind == .web ? LinkKind.url(link) : nil
        let title =
            LinkText.isBlank(parsed.title)
            ? LinkText.fallbackTitle(for: link, url: webURL) : LinkText.oneLine(parsed.title, limit: titleLimit)
        let identity: String
        if let guid = parsed.guid, !guid.isEmpty, guid.utf8.count <= 64, !guid.utf8.contains(UInt8(ascii: "/")) {
            identity = guid
        } else {
            let fingerprint = ([link, parsed.title] + parsed.folders).joined(separator: "\u{1F}")
            identity = "h" + String(FNV1a.hash64(fingerprint), radix: 16)
        }
        var key = profileID + "/" + identity
        if !usedKeys.insert(key).inserted {
            var copy = 2
            while !usedKeys.insert(key + "~\(copy)").inserted { copy += 1 }
            key += "~\(copy)"
        }
        return Bookmark(
            key: key, title: title, link: link, kind: kind, webURL: webURL, host: webURL.flatMap(LinkText.host(of:)),
            folders: parsed.folders.map { LinkText.oneLine($0, limit: 80) }, browser: profile.browser,
            profileID: profileID, profileName: profileName, dateAdded: parsed.dateAdded,
            isReadingList: parsed.isReadingList, isOnBar: parsed.isOnBar)
    }

    /// The folder path as the subtitle: "Bookmarks bar › Work". The outer folders give way first.
    static func subtitle(_ folders: [String]) -> String {
        let named = folders.filter { !$0.isEmpty }
        guard !named.isEmpty else { return Strings.Folders.topLevel }
        guard named.count > subtitleFolders else { return named.joined(separator: Strings.Folders.separator) }
        return ([Strings.Folders.more] + named.suffix(subtitleFolders - 1)).joined(separator: Strings.Folders.separator)
    }

    static func row(_ bookmark: Bookmark, showsProfile: Bool, forCatalog: Bool = false) -> Row {
        var accessories: [Accessory] = []
        if let tag = Strings.kindTag(bookmark.kind, link: bookmark.link) { accessories.append(.tag(tag)) }
        if showsProfile { accessories.append(.text(bookmark.profileName)) }
        var keywords: [String] = []
        if let host = bookmark.host { keywords.append(host) }
        if !forCatalog { keywords.append(capped(bookmark.link, 200)) }
        let payload = BookmarkPayload(
            link: bookmark.link.utf8.count <= payloadLinkLimit ? bookmark.link : nil,
            title: capped(bookmark.title, 100), browser: bookmark.browser, kind: bookmark.kind)
        let represents = bookmark.webURL.map(Selection.url)
        return Row(
            id: ItemID(namespace, bookmark.key), title: bookmark.title, subtitle: subtitle(bookmark.folders),
            icon: .app(bundleID: bookmark.browser.bundleID), accessories: accessories, keywords: keywords,
            payload: Payload(payload), represents: represents)
    }

    /// The text, cut to `limit` characters only when it may be longer: counting bytes is cheap,
    /// counting characters is not.
    private static func capped(_ text: String, _ limit: Int) -> String {
        text.utf8.count <= limit ? text : String(text.prefix(limit))
    }

    /// Root search's rows: links that can be opened, the first of each link, newest first after
    /// the bookmarks bar and favorites, at most ``catalogLimit``.
    private static func catalogRows(_ bookmarks: [Bookmark], rows: [Row]) -> [Row] {
        var seen = Set<String>(minimumCapacity: bookmarks.count)
        var picked: [Int] = []
        for (index, bookmark) in bookmarks.enumerated() where bookmark.kind.opens {
            if seen.insert(bookmark.link).inserted { picked.append(index) }
        }
        if picked.count > catalogLimit {
            // Sorts positions, not bookmarks, so nothing large moves.
            let onBar = bookmarks.map(\.isOnBar)
            let added = bookmarks.map { $0.dateAdded?.timeIntervalSince1970 ?? -.infinity }
            picked.sort { left, right in
                if onBar[left] != onBar[right] { return onBar[left] }
                return added[left] != added[right] ? added[left] > added[right] : left < right
            }
            picked = Array(picked.prefix(catalogLimit)).sorted()
        }
        return picked.map { row(bookmarks[$0], showsProfile: false, forCatalog: true) }
    }
}

/// What the list's dropdown narrows to.
nonisolated enum BookmarkFilter: Hashable, Sendable {
    case all
    case browser(Browser)
    case profile(String)
    case readingList

    init(optionID: String?) {
        guard let optionID else {
            self = .all
            return
        }
        if optionID == "reading-list" {
            self = .readingList
        } else if optionID.hasPrefix("browser:"), let browser = Browser(rawValue: String(optionID.dropFirst(8))) {
            self = .browser(browser)
        } else if optionID.hasPrefix("profile:") {
            self = .profile(String(optionID.dropFirst(8)))
        } else {
            self = .all
        }
    }

    var optionID: String {
        switch self {
        case .all: "all"
        case .browser(let browser): "browser:" + browser.rawValue
        case .profile(let id): "profile:" + id
        case .readingList: "reading-list"
        }
    }

    func matches(_ bookmark: Bookmark) -> Bool {
        switch self {
        case .all: true
        case .browser(let browser): bookmark.browser == browser
        case .profile(let id): bookmark.profileID == id
        case .readingList: bookmark.isReadingList
        }
    }

    /// The dropdown for the profiles in a snapshot: All, then each browser with its profiles when it
    /// has more than one, and Safari's Reading List when it has items.
    static func dropdown(for profiles: [ProfileSummary]) -> FilterDropdown {
        var options = [FilterOption(id: BookmarkFilter.all.optionID, title: Strings.List.allBrowsers)]
        let byBrowser = Dictionary(grouping: profiles, by: \.browser)
        for browser in Browser.allCases {
            guard let list = byBrowser[browser], !list.isEmpty else { continue }
            let section = browser.name
            options.append(
                FilterOption(
                    id: BookmarkFilter.browser(browser).optionID,
                    title: list.count > 1 ? Strings.List.allProfiles : browser.name,
                    icon: .app(bundleID: browser.bundleID), section: section))
            if list.count > 1 {
                for profile in list {
                    options.append(
                        FilterOption(
                            id: BookmarkFilter.profile(profile.id).optionID, title: profile.name, section: section))
                }
            }
            if browser == .safari, list.contains(where: { $0.readingListCount > 0 }) {
                options.append(
                    FilterOption(
                        id: BookmarkFilter.readingList.optionID, title: Strings.List.readingList, section: section))
            }
        }
        return FilterDropdown(title: Strings.List.filterTitle, options: options, defaultID: BookmarkFilter.all.optionID)
    }
}
