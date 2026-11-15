import Kit

/// What a history item holds. It decides the item's icon, its preview, its actions and which
/// filter option shows it. The raw value is what the database stores.
nonisolated enum ClipKind: String, CaseIterable, Codable, Hashable, Sendable {
    case text
    case richText = "rich-text"
    case link
    case color
    case image
    case files

    /// True for items whose content is text: they can be searched, pasted as plain text and saved
    /// as a snippet, and they answer the `{clipboard}` placeholder.
    var isTextual: Bool {
        switch self {
        case .text, .richText, .link, .color: true
        case .image, .files: false
        }
    }

    /// The SF Symbol for the kind, used where the item has no icon of its own.
    var symbol: String {
        switch self {
        case .text: "doc.plaintext"
        case .richText: "doc.richtext"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

/// The options of the type dropdown on the history page.
nonisolated enum KindFilter: String, CaseIterable, Sendable {
    case all
    case pinned
    case text
    case images
    case links
    case files
    case colors

    /// The kinds the option shows. Nil shows every kind.
    var kinds: [ClipKind]? {
        switch self {
        case .all, .pinned: nil
        case .text: [.text, .richText]
        case .images: [.image]
        case .links: [.link]
        case .files: [.files]
        case .colors: [.color]
        }
    }

    /// The option for a dropdown ID, or All for an unknown one.
    init(optionID: String?) {
        self = optionID.flatMap(KindFilter.init(rawValue:)) ?? .all
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .pinned: "pin"
        case .text: ClipKind.text.symbol
        case .images: ClipKind.image.symbol
        case .links: ClipKind.link.symbol
        case .files: ClipKind.files.symbol
        case .colors: ClipKind.color.symbol
        }
    }

    /// The dropdown, Command-P on the history page. It remembers the user's choice.
    static let dropdown = FilterDropdown(
        title: Strings.Filter.title,
        options: allCases.map {
            FilterOption(id: $0.rawValue, title: Strings.Filter.title(for: $0), icon: .symbol($0.symbol))
        },
        defaultID: KindFilter.all.rawValue)
}
