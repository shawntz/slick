import Kit

/// One emoji or symbol in the catalog, as the data file describes it, without a skin tone applied.
nonisolated struct EmojiEntry: Hashable, Sendable {
    /// The fully qualified emoji, or the symbol.
    let glyph: String
    /// The CLDR short name in title case, such as "Thumbs Up".
    let name: String
    let group: EmojiGroup
    /// The Emoji version the emoji arrived in, such as "13.1". Empty for symbols.
    let version: String
    /// 1 for the most used emoji, then 2 and so on. 0 for the rest.
    let commonRank: Int
    /// Lowercase words search matches besides the name.
    let keywords: [String]
    /// No variants, 5 for one person from light to dark, or 25 for two people. See ``SkinTones``.
    let variants: [String]
    /// The item key: the code points in lowercase hex without U+FE0F, joined by "-", such as "1f44d".
    /// It does not change with the skin tone or the name.
    let key: String

    init(
        glyph: String, name: String, group: EmojiGroup, version: String = "", commonRank: Int = 0,
        keywords: [String] = [], variants: [String] = []
    ) {
        self.glyph = glyph
        self.name = name
        self.group = group
        self.version = version
        self.commonRank = commonRank
        self.keywords = keywords
        self.variants = variants
        self.key = Self.key(for: glyph)
    }

    /// Which skin tones the emoji takes.
    var skinTones: SkinTones {
        switch variants.count {
        case SkinTone.toneCount: .onePerson
        case SkinTone.toneCount * SkinTone.toneCount: .twoPeople
        default: .none
        }
    }

    /// The emoji in a skin tone: the default tone for every person in it. Unchanged when the emoji
    /// takes no skin tone or the tone is ``SkinTone/none``.
    func glyph(in tone: SkinTone) -> String {
        glyph(in: tone, tone)
    }

    /// The emoji with one tone per person. A one-person emoji uses only the first.
    func glyph(in first: SkinTone, _ second: SkinTone) -> String {
        switch skinTones {
        case .none:
            return glyph
        case .onePerson:
            guard let index = first.index else { return glyph }
            return variants[index]
        case .twoPeople:
            // A two-person emoji has no variant with one person in the default tone.
            guard let firstIndex = first.index, let secondIndex = (second.index ?? first.index) else { return glyph }
            return variants[firstIndex * SkinTone.toneCount + secondIndex]
        }
    }

    /// The code points as people write them, such as "U+1F44D U+1F3FD".
    static func codePoints(of text: String) -> String {
        text.unicodeScalars.map { scalar in
            let hex = String(scalar.value, radix: 16, uppercase: true)
            return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        }
        .joined(separator: " ")
    }

    /// The key for a glyph. See ``key``.
    static func key(for glyph: String) -> String {
        glyph.unicodeScalars.lazy.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }
            .joined(separator: "-")
    }
}

/// Which skin tones an emoji takes.
nonisolated enum SkinTones: Hashable, Sendable {
    case none
    /// One person: five variants, light to dark.
    case onePerson
    /// Two people, such as people holding hands: one tone each, 25 variants. Variant (a, b) is at
    /// index a * 5 + b, so the uniform tones are at 0, 6, 12, 18 and 24.
    case twoPeople
}

/// A skin tone: the default the user picks in settings, or one picked for a single emoji.
nonisolated enum SkinTone: String, CaseIterable, Sendable, SettingValue {
    case none, light, mediumLight, medium, mediumDark, dark

    /// The number of tones besides ``none``.
    static let toneCount = 5

    /// The tones besides ``none``, light to dark.
    static let tones: [SkinTone] = [.light, .mediumLight, .medium, .mediumDark, .dark]

    /// 0 for light to 4 for dark; nil for the default yellow.
    var index: Int? {
        switch self {
        case .none: nil
        case .light: 0
        case .mediumLight: 1
        case .medium: 2
        case .mediumDark: 3
        case .dark: 4
        }
    }
}

/// The groups of the grid: Unicode's emoji groups in Unicode's order, then the symbol sets. The raw
/// values are the group numbers in the data file.
nonisolated enum EmojiGroup: Int, CaseIterable, Sendable {
    case smileys, people, animals, food, travel, activities, objects, symbols, flags
    case arrows, math, greek, currency, punctuation, keyboard, shapes, boxDrawing

    /// True for Unicode's emoji groups, false for the symbol sets.
    var isEmoji: Bool { rawValue <= EmojiGroup.flags.rawValue }

    /// The ID of the group's option in the grid's category dropdown and of its section.
    var id: String {
        switch self {
        case .smileys: "smileys"
        case .people: "people"
        case .animals: "animals"
        case .food: "food"
        case .travel: "travel"
        case .activities: "activities"
        case .objects: "objects"
        case .symbols: "symbols"
        case .flags: "flags"
        case .arrows: "arrows"
        case .math: "math"
        case .greek: "greek"
        case .currency: "currency"
        case .punctuation: "punctuation"
        case .keyboard: "keyboard"
        case .shapes: "shapes"
        case .boxDrawing: "box-drawing"
        }
    }

    /// The group with this dropdown option ID.
    init?(id: String) {
        guard let group = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = group
    }
}
