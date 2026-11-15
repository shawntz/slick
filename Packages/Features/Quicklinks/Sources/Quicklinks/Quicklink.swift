import Foundation
import Kit

/// One quicklink as stored. `nonisolated` so the JSON store encodes it off the main actor.
///
/// Every field but the ID, name and link may be missing from the file, so a person can write one by
/// hand and an older file still reads.
nonisolated struct Quicklink: Codable, Hashable, Sendable, Identifiable {
    /// Stable across launches: the key of the catalog row and of the command. Built-in searches use
    /// short IDs such as `google`.
    var id: String
    var name: String
    /// The link template. See ``LinkTemplate``.
    var link: String
    /// Words root search matches besides the name, such as `g` for Google.
    var keywords: [String] = []
    /// The app that opens the link, by bundle ID. Nil uses the default app.
    var openWith: String?
    /// An SF Symbol name. Nil shows the site's icon.
    var icon: String?
    var isEnabled = true
    /// Offered under root results when nothing matches, if the link takes the query.
    var isFallback = false
    /// True for one of the built-in web searches. Restoring the defaults resets these by ID.
    var isBuiltIn = false

    init(
        id: String, name: String, link: String, keywords: [String] = [], openWith: String? = nil,
        icon: String? = nil, isEnabled: Bool = true, isFallback: Bool = false, isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.keywords = keywords
        self.openWith = openWith
        self.icon = icon
        self.isEnabled = isEnabled
        self.isFallback = isFallback
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, link, keywords, openWith, icon
        case isEnabled = "enabled"
        case isFallback = "fallback"
        case isBuiltIn = "builtIn"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        link = try container.decode(String.self, forKey: .link)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        openWith = try container.decodeIfPresent(String.self, forKey: .openWith)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isFallback = try container.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(link, forKey: .link)
        if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
        try container.encodeIfPresent(openWith, forKey: .openWith)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(isEnabled, forKey: .isEnabled)
        if isFallback { try container.encode(isFallback, forKey: .isFallback) }
        if isBuiltIn { try container.encode(isBuiltIn, forKey: .isBuiltIn) }
    }

    /// The command that opens a quicklink with arguments: `open.<id>`.
    var commandID: String { "open." + id }

    /// True for the characters a quicklink ID may use, so its command ID is valid: 1 to 64 ASCII
    /// letters, digits, ".", "-" or "_".
    static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }

    /// A new ID for a quicklink the user makes.
    static func makeID() -> String {
        UUID().uuidString.lowercased()
    }
}

/// The quicklinks file. `nonisolated` so the JSON store encodes it off the main actor.
nonisolated struct QuicklinkFile: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version = QuicklinkFile.currentVersion
    var quicklinks: [Quicklink]
    /// Built-in searches the user deleted, by ID, so they stay deleted when a later version adds
    /// more built-ins.
    var removedDefaults: [String] = []

    init(quicklinks: [Quicklink], removedDefaults: [String] = []) {
        self.quicklinks = quicklinks
        self.removedDefaults = removedDefaults
    }

    private enum CodingKeys: String, CodingKey {
        case version, quicklinks, removedDefaults
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        quicklinks = try container.decode([Quicklink].self, forKey: .quicklinks)
        removedDefaults = try container.decodeIfPresent([String].self, forKey: .removedDefaults) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(quicklinks, forKey: .quicklinks)
        try container.encode(removedDefaults, forKey: .removedDefaults)
    }

    /// The file on first launch: every built-in search.
    static var defaults: QuicklinkFile {
        QuicklinkFile(quicklinks: DefaultSearches.all)
    }

    /// The file as read, made safe to use: every ID valid and unique, every name one line and not
    /// empty, and every built-in search that is neither present nor deleted added at the end. A file
    /// written by hand or by an older version comes out usable, and the next save writes the result.
    func prepared() -> QuicklinkFile {
        var seen = Set<String>()
        var result: [Quicklink] = []
        for var quicklink in quicklinks {
            if !Quicklink.isValidID(quicklink.id) {
                quicklink.id = "q" + String(FNV1a.hash64(quicklink.id), radix: 16)
            }
            var id = quicklink.id
            var suffix = 2
            while seen.contains(id) {
                // The suffix keeps the ID valid, so the next load does not change it again.
                let tail = "-\(suffix)"
                id = String(quicklink.id.prefix(64 - tail.count)) + tail
                suffix += 1
            }
            quicklink.id = id
            seen.insert(id)
            // A row title is one line.
            if quicklink.name.contains(where: \.isNewline) {
                quicklink.name = quicklink.name.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
            if quicklink.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                quicklink.name = Strings.untitled
            }
            result.append(quicklink)
        }
        let removed = Set(removedDefaults)
        for builtIn in DefaultSearches.all where !seen.contains(builtIn.id) && !removed.contains(builtIn.id) {
            result.append(builtIn)
            seen.insert(builtIn.id)
        }
        var file = self
        file.quicklinks = result
        return file
    }
}
