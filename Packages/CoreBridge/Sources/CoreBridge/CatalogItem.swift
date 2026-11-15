import SlickCoreC

/// The kind of an item. The engine gives some kinds a static prior inside their text tier.
public struct ItemKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Anything else.
    public static let other = ItemKind(rawValue: UInt8(SLICK_KIND_OTHER))
    /// An application.
    public static let app = ItemKind(rawValue: UInt8(SLICK_KIND_APP))
    /// A command of a feature or extension.
    public static let command = ItemKind(rawValue: UInt8(SLICK_KIND_COMMAND))
    /// A file or folder.
    public static let file = ItemKind(rawValue: UInt8(SLICK_KIND_FILE))
    /// A settings pane.
    public static let setting = ItemKind(rawValue: UInt8(SLICK_KIND_SETTING))
    /// A contact.
    public static let contact = ItemKind(rawValue: UInt8(SLICK_KIND_CONTACT))
}

/// Per-item opt-outs.
public struct ItemFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Never shown in the zero-query suggestions (destructive or noisy commands).
    public static let noSuggest = ItemFlags(rawValue: UInt32(SLICK_ITEM_NO_SUGGEST))
    /// Executions are not learned (password generators and the like).
    public static let noLearn = ItemFlags(rawValue: UInt32(SLICK_ITEM_NO_LEARN))
}

/// One searchable item: what a catalog source or a feature's index holds.
public struct CatalogItem: Hashable, Sendable {
    /// The item's identity.
    public var key: ItemKey
    /// Display title, matched first.
    public var title: String
    /// Alternate names that count almost like the title.
    public var aliases: [String]
    /// Weaker search terms, ranked one tier below the same match on the title.
    public var keywords: [String]
    /// Sets a static prior inside the text tier.
    public var kind: ItemKind
    /// The item's own static prior in [0, 1], added to its kind prior.
    public var prior: Float
    /// Opt-outs.
    public var flags: ItemFlags

    public init(
        key: ItemKey,
        title: String,
        aliases: [String] = [],
        keywords: [String] = [],
        kind: ItemKind = .other,
        prior: Float = 0,
        flags: ItemFlags = []
    ) {
        self.key = key
        self.title = title
        self.aliases = aliases
        self.keywords = keywords
        self.kind = kind
        self.prior = prior
        self.flags = flags
    }
}

/// Packs items into the C layout: an array of `SlickItem` whose strings are spans of one UTF-8
/// buffer. Aliases and keywords are joined with the unit separator, so they must not contain it.
struct PackedItems {
    var items: [SlickItem] = []
    var strings: [UInt8] = []

    init(_ list: [CatalogItem]) throws(CoreError) {
        items.reserveCapacity(list.count)
        for item in list {
            let title = try append(item.title)
            let aliases = try append(item.aliases)
            let keywords = try append(item.keywords)
            var packed = SlickItem()
            packed.key = item.key.rawValue
            (packed.title_start, packed.title_len) = title
            (packed.aliases_start, packed.aliases_len) = aliases
            (packed.keywords_start, packed.keywords_len) = keywords
            packed.prior = item.prior
            packed.flags = item.flags.rawValue
            packed.kind = item.kind.rawValue
            items.append(packed)
        }
    }

    private mutating func append(_ list: [String]) throws(CoreError) -> (UInt32, UInt32) {
        let separator = UInt8(SLICK_LIST_SEPARATOR)
        let start = strings.count
        for (i, s) in list.enumerated() {
            if s.utf8.contains(separator) { throw .invalidArgument }
            if i > 0 { strings.append(separator) }
            strings.append(contentsOf: s.utf8)
        }
        return try span(start)
    }

    private mutating func append(_ s: String) throws(CoreError) -> (UInt32, UInt32) {
        let start = strings.count
        strings.append(contentsOf: s.utf8)
        return try span(start)
    }

    private func span(_ start: Int) throws(CoreError) -> (UInt32, UInt32) {
        guard let s = UInt32(exactly: start), let n = UInt32(exactly: strings.count - start) else {
            throw .invalidArgument
        }
        return (s, n)
    }

    /// Calls `body` with pointers to the items and the strings.
    func withPointers(
        _ body: (UnsafePointer<SlickItem>?, Int, UnsafePointer<UInt8>?, Int) -> Int32
    ) -> Int32 {
        items.withUnsafeBufferPointer { i in
            strings.withUnsafeBufferPointer { s in
                body(i.baseAddress, i.count, s.baseAddress, s.count)
            }
        }
    }
}
