import Foundation
import Kit

/// One snippet as stored. `nonisolated` so the JSON store can encode it off the main actor.
///
/// Every field but the name and the text may be missing from the file, so a snippet written by
/// hand still loads.
nonisolated struct Snippet: Hashable, Sendable, Identifiable {
    /// Stable across launches and renames, so learning and usage follow the snippet.
    var id: String
    /// Unique among snippets, so `{snippet name="..."}` finds one.
    var name: String
    /// The template, with `{placeholders}`.
    var text: String
    /// Typed in any app to insert the snippet, without the shared prefix from settings.
    var keyword: String?
    var collection: String?
    /// False keeps the keyword from expanding as you type. The keyword still finds the snippet in
    /// root search.
    var expands: Bool
    var isPinned: Bool
    var created: Date?
    var modified: Date?

    init(
        id: String, name: String, text: String, keyword: String? = nil, collection: String? = nil,
        expands: Bool = true, isPinned: Bool = false, created: Date? = nil, modified: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = Self.clean(keyword)
        self.collection = Self.clean(collection)
        self.expands = expands
        self.isPinned = isPinned
        self.created = created
        self.modified = modified
    }

    /// The keyword as typed, with the shared prefix.
    func typedKeyword(prefix: String) -> String? {
        keyword.map { prefix + $0 }
    }

    /// An ID for a snippet that has none, such as one added to the file by hand. It depends only on
    /// the name and text, so it stays the same on every load.
    static func derivedID(name: String, text: String) -> String {
        "h" + String(FNV1a.hash64(name + "\u{0}" + text), radix: 16)
    }

    /// Nil for missing or blank text; otherwise the text without surrounding white space.
    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension Snippet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, text, keyword, collection, expands, pinned, created, modified
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let text = try container.decode(String.self, forKey: .text)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? Self.derivedID(name: name, text: text),
            name: name,
            text: text,
            keyword: try container.decodeIfPresent(String.self, forKey: .keyword),
            collection: try container.decodeIfPresent(String.self, forKey: .collection),
            expands: try container.decodeIfPresent(Bool.self, forKey: .expands) ?? true,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
            created: try container.decodeIfPresent(Date.self, forKey: .created),
            modified: try container.decodeIfPresent(Date.self, forKey: .modified))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(keyword, forKey: .keyword)
        try container.encodeIfPresent(collection, forKey: .collection)
        try container.encode(expands, forKey: .expands)
        try container.encode(isPinned, forKey: .pinned)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encodeIfPresent(modified, forKey: .modified)
    }
}

/// The snippets file: a version, so a later format can tell old files apart, and the snippets in
/// the user's order.
nonisolated struct SnippetFile: Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var snippets: [Snippet]

    init(snippets: [Snippet], version: Int = Self.currentVersion) {
        self.version = version
        self.snippets = snippets
    }
}

extension SnippetFile: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, snippets
    }

    /// Reads the versioned form, and a bare array of snippets too, which a person may write by hand.
    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.init(
                snippets: try container.decode([Snippet].self, forKey: .snippets),
                version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion)
        } else {
            self.init(snippets: try decoder.singleValueContainer().decode([Snippet].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(snippets, forKey: .snippets)
    }
}

/// What the editor form fills in, for a new snippet or an existing one.
nonisolated struct SnippetDraft: Hashable, Sendable {
    var name: String
    var text: String
    var keyword: String
    var collection: String
    var expands: Bool

    init(name: String = "", text: String = "", keyword: String = "", collection: String = "", expands: Bool = true) {
        self.name = name
        self.text = text
        self.keyword = keyword
        self.collection = collection
        self.expands = expands
    }

    init(_ snippet: Snippet) {
        self.init(
            name: snippet.name, text: snippet.text, keyword: snippet.keyword ?? "",
            collection: snippet.collection ?? "", expands: snippet.expands)
    }

    /// The name and keyword as they will be saved.
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanKeyword: String? { Snippet.clean(keyword) }
    var cleanCollection: String? { Snippet.clean(collection) }
}
