import CoreGraphics
import Foundation

/// A small icon before an action or option title.
nonisolated public enum CardIcon: Sendable, Equatable {
    /// An image, drawn as is.
    case image(CGImage)
    /// An SF Symbol, tinted with the row's text colour.
    case symbol(String)

    public static func == (lhs: CardIcon, rhs: CardIcon) -> Bool {
        switch (lhs, rhs) {
        case (.image(let a), .image(let b)): a === b
        case (.symbol(let a), .symbol(let b)): a == b
        default: false
        }
    }
}

/// One row of the action card or a dropdown menu.
nonisolated public struct ActionItem: Sendable, Equatable {
    /// Reported back when the row runs.
    public var id: String
    public var title: String
    /// Matched runs of the title while the card is filtered, in UTF-16 offsets.
    public var titleHighlights: [HighlightRange]
    public var icon: CardIcon?
    /// The action's shortcut, one keycap per key: `["⌘", "C"]`.
    public var keys: [String]
    /// Drawn in the destructive colour.
    public var isDestructive: Bool
    /// Shows a checkmark, as the selected option of a dropdown does.
    public var isChecked: Bool

    public init(
        id: String, title: String, titleHighlights: [HighlightRange] = [], icon: CardIcon? = nil, keys: [String] = [],
        isDestructive: Bool = false, isChecked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleHighlights = titleHighlights
        self.icon = icon
        self.keys = keys
        self.isDestructive = isDestructive
        self.isChecked = isChecked
    }
}

/// Actions under an optional section title.
nonisolated public struct ActionSection: Sendable, Equatable {
    public var title: String?
    public var items: [ActionItem]

    public init(title: String? = nil, items: [ActionItem]) {
        self.title = title
        self.items = items
    }
}

/// Everything the action card shows.
nonisolated public struct ActionCardContent: Sendable, Equatable {
    public var sections: [ActionSection]
    /// The filter field's placeholder.
    public var placeholder: String

    public init(sections: [ActionSection], placeholder: String = "Search for actions…") {
        self.sections = sections
        self.placeholder = placeholder
    }

    public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// The item at `index`, counted across sections.
    public func item(at index: Int) -> ActionItem? {
        var remaining = index
        for section in sections {
            if remaining < section.items.count { return remaining >= 0 ? section.items[remaining] : nil }
            remaining -= section.items.count
        }
        return nil
    }

    /// The items whose titles match `query`, in one untitled section, best first: titles that
    /// start with the query, then titles with a word that starts with it, then titles that contain
    /// it. Matching ignores case and diacritics. An empty query returns the content unchanged.
    ///
    /// A plain filter for small menus. Hosts with the engine's matcher can filter themselves and
    /// call `ActionCardView.apply(_:)` instead.
    public func filtered(by query: String) -> ActionCardContent {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return self }
        var ranked: [(tier: Int, order: Int, item: ActionItem)] = []
        var order = 0
        for section in sections {
            for item in section.items {
                defer { order += 1 }
                let title = item.title as NSString
                let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                let found = title.range(of: needle, options: options)
                guard found.location != NSNotFound else { continue }
                let tier: Int
                if found.location == 0 {
                    tier = 0
                } else if title.character(at: found.location - 1) == 32 {
                    tier = 1
                } else {
                    tier = 2
                }
                var match = item
                match.titleHighlights = [HighlightRange(location: found.location, length: found.length)]
                ranked.append((tier, order, match))
            }
        }
        ranked.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.order < $1.order }
        return ActionCardContent(sections: [ActionSection(items: ranked.map(\.item))], placeholder: placeholder)
    }
}

/// One choice in a dropdown: a filter, an argument or a form field.
nonisolated public struct MenuOption: Sendable, Equatable {
    /// Reported back when chosen.
    public var id: String
    public var title: String
    public var icon: CardIcon?
    /// Consecutive options with the same section title are grouped under it.
    public var section: String?

    public init(id: String, title: String, icon: CardIcon? = nil, section: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
    }
}
