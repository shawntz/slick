import Foundation

/// One result: what the host draws for an item in a list, a grid or root search.
///
/// A row is plain data. Build it on any thread, keep it in arrays of any size, compare and encode
/// it. It holds no behavior: the source that made the row derives its actions from it when they are
/// needed (see ``RowActionProvider``).
public struct Row: Identifiable, Hashable, Sendable {
    /// The row's identity. Stable across launches.
    public var id: ItemID
    /// The main text. Host filtering matches against it.
    public var title: String
    /// Secondary text, drawn after or under the title.
    public var subtitle: String?
    /// A color for the subtitle, such as red for a script that failed. Nil uses the theme's. The
    /// host keeps it readable: it moves the color toward the theme's text color until it meets the
    /// theme's contrast rule for secondary text, so a pale color may draw darker than asked.
    public var subtitleColor: KitColor?
    /// The leading icon, or the cell content in a grid.
    public var icon: Icon?
    /// Trailing items: text, tags, dates, icons, shortcuts.
    public var accessories: [Accessory]
    /// Extra words that host filtering matches, such as aliases or content not shown in the title.
    public var keywords: [String]
    /// Data the source needs to rebuild the row's actions. See ``Payload``.
    public var payload: Payload?
    /// Text that Tab puts into the search field, for example a folder path or a calculator answer.
    /// Tab uses the selected row's completion when it has one, and the user's Tab command otherwise.
    public var completion: String?
    /// A local file to preview when the user presses Command-Y. An action whose shortcut is
    /// Command-Y takes precedence.
    public var quickLookURL: URL?
    /// Different subtitles or icons shown while modifier keys are held. Pair each with an action whose
    /// shortcut is Return plus the same modifiers, so the row shows what that key will do.
    public var alternates: [Alternate]
    /// Matched ranges of the title in UTF-16 offsets, for rows the host does not filter itself: a
    /// custom-filtered list or an async provider. Host filtering computes its own and ignores these.
    /// Left out when the row is encoded.
    public var titleHighlights: [Range<Int>]
    /// Orders rows inside one match tier under host filtering, after the rows whose title made the
    /// match: higher first, then the host's usual order. Use it for recency or frequency inside a
    /// feature. A weaker tier never outranks a stronger one, whatever the hint.
    public var rankHint: Double
    /// What root search keeps after the user runs the row.
    public var memory: RowMemory
    /// After this moment root search drops the row from its catalog without waiting for a reload,
    /// such as a meeting that has ended.
    public var expires: Date?
    /// What the row stands for, so the host can offer every feature's universal actions for it in
    /// the action panel, as it does for a selection in another app.
    public var represents: Selection?

    public init(
        id: ItemID,
        title: String,
        subtitle: String? = nil,
        icon: Icon? = nil,
        accessories: [Accessory] = [],
        keywords: [String] = [],
        payload: Payload? = nil,
        completion: String? = nil,
        quickLookURL: URL? = nil,
        alternates: [Alternate] = [],
        titleHighlights: [Range<Int>] = [],
        rankHint: Double = 0,
        memory: RowMemory = .remember,
        expires: Date? = nil,
        represents: Selection? = nil,
        subtitleColor: KitColor? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessories = accessories
        self.keywords = keywords
        self.payload = payload
        self.completion = completion
        self.quickLookURL = quickLookURL
        self.alternates = alternates
        self.titleHighlights = titleHighlights
        self.rankHint = rankHint
        self.memory = memory
        self.expires = expires
        self.represents = represents
        self.subtitleColor = subtitleColor
    }

    /// What a row shows while a set of modifier keys is held.
    public struct Alternate: Hashable, Sendable, Codable {
        /// The modifiers that must be held, exactly.
        public var modifiers: KeyModifiers
        /// The subtitle shown instead of the row's own. Nil keeps the row's subtitle.
        public var subtitle: String?
        /// The icon shown instead of the row's own. Nil keeps the row's icon.
        public var icon: Icon?

        public init(modifiers: KeyModifiers, subtitle: String? = nil, icon: Icon? = nil) {
            self.modifiers = modifiers
            self.subtitle = subtitle
            self.icon = icon
        }
    }

    /// The alternate for exactly these held modifiers, if any.
    public func alternate(for modifiers: KeyModifiers) -> Alternate? {
        alternates.first { $0.modifiers == modifiers }
    }
}

/// What root search keeps after the user runs a row.
public enum RowMemory: String, Hashable, Sendable, Codable {
    /// Root learns from the run and keeps a snapshot of the row, which joins the catalog, so the
    /// item can be found by name later. The default.
    case remember
    /// Root learns from the run but keeps no snapshot. The row ranks well when its source offers it
    /// again. For rows that make sense only while their source shows them.
    case learnOnly
    /// Root records nothing. For answers to one query, such as a calculation, or one occurrence of
    /// an event.
    case never
}

/// Rows are encoded when root search remembers them. Every field but the ID and title may be
/// missing, so snapshots written by an older version still decode. Highlights are left out.
extension Row: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon, accessories, keywords, payload, completion, quickLookURL, alternates
        case rankHint, memory, expires, represents, subtitleColor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ItemID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle),
            icon: try container.decodeIfPresent(Icon.self, forKey: .icon),
            accessories: try container.decodeIfPresent([Accessory].self, forKey: .accessories) ?? [],
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords) ?? [],
            payload: try container.decodeIfPresent(Payload.self, forKey: .payload),
            completion: try container.decodeIfPresent(String.self, forKey: .completion),
            quickLookURL: try container.decodeIfPresent(URL.self, forKey: .quickLookURL),
            alternates: try container.decodeIfPresent([Alternate].self, forKey: .alternates) ?? [],
            rankHint: try container.decodeIfPresent(Double.self, forKey: .rankHint) ?? 0,
            memory: try container.decodeIfPresent(RowMemory.self, forKey: .memory) ?? .remember,
            expires: try container.decodeIfPresent(Date.self, forKey: .expires),
            represents: try container.decodeIfPresent(Selection.self, forKey: .represents),
            subtitleColor: try container.decodeIfPresent(KitColor.self, forKey: .subtitleColor))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(icon, forKey: .icon)
        if !accessories.isEmpty { try container.encode(accessories, forKey: .accessories) }
        if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encodeIfPresent(completion, forKey: .completion)
        try container.encodeIfPresent(quickLookURL, forKey: .quickLookURL)
        if !alternates.isEmpty { try container.encode(alternates, forKey: .alternates) }
        if rankHint != 0 { try container.encode(rankHint, forKey: .rankHint) }
        if memory != .remember { try container.encode(memory, forKey: .memory) }
        try container.encodeIfPresent(expires, forKey: .expires)
        try container.encodeIfPresent(represents, forKey: .represents)
        try container.encodeIfPresent(subtitleColor, forKey: .subtitleColor)
    }
}
