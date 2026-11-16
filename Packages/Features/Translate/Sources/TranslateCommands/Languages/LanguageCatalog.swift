import Foundation

/// The languages the engine offers, with their names, built once off the main thread. Pure.
///
/// The list comes from the engine, never from a table here. Names come from Foundation: each
/// language is shown in the app's own language and can be typed in the user's language or in
/// English, so "to french" and, for a German user, "to französisch" both find French. Lookups by
/// name cost one fold of a short string and one dictionary read, cheap enough for a keystroke.
nonisolated struct LanguageCatalog: Sendable {
    /// One language and how it is shown.
    nonisolated struct Entry: Hashable, Sendable {
        let tag: LanguageTag
        /// The name shown in menus, such as "French", or "English (United Kingdom)" when the Mac
        /// offers more than one English.
        let title: String
    }

    /// What a text's language turned out to be.
    nonisolated enum Source: Hashable, Sendable {
        /// A language the engine offers.
        case supported(LanguageTag)
        /// A language the engine does not offer, as the recognizer named it, such as "is".
        case unsupported(String)
        /// No language was recognized.
        case unknown
    }

    /// A second guess that can be translated is used instead of a first guess that cannot when it
    /// is at least this share as likely.
    static let secondGuessShare = 0.5
    /// The longest name looked up, in UTF-8 bytes. Language names are much shorter.
    static let maximumNameBytes = 64

    /// Every language the engine offers, sorted by title.
    let entries: [Entry]
    /// What Automatic translates into: the user's first preferred language the engine offers,
    /// else English, else the first language. Nil only when the engine offers none.
    let automaticTarget: LanguageTag?
    /// English as the engine offers it, if it does.
    let english: LanguageTag?
    /// The locale the titles are in.
    let display: Locale
    private let indexByIdentifier: [String: Int]
    private let languagesByName: [String: LanguageTag]
    /// The variant a bare language name means, by language code.
    private let primaryByCode: [String: LanguageTag]

    /// A catalog with no languages, as when translation is not available.
    static func empty(display: Locale) -> LanguageCatalog {
        make(supported: [], preferred: [], display: display)
    }

    /// Builds the catalog. Costs a few name lookups per language, so call it off the main thread.
    ///
    /// - Parameters:
    ///   - supported: The engine's languages, in its order.
    ///   - preferred: The user's preferred languages, best first, as BCP 47 identifiers.
    ///   - display: The locale titles are written in.
    static func make(supported: [LanguageTag], preferred: [String], display: Locale) -> LanguageCatalog {
        var seen = Set<LanguageTag>()
        let tags = supported.filter { seen.insert($0).inserted }
        let preferredTags = preferred.map(LanguageTag.init)
        let byCode = Dictionary(grouping: tags, by: \.code)

        var titled: [Entry] = []
        for tag in tags {
            let group = byCode[tag.code] ?? [tag]
            let title: String
            if group.count == 1 {
                title = display.localizedString(forLanguageCode: tag.code) ?? tag.identifier
            } else {
                title = display.localizedString(forIdentifier: variantIdentifier(tag, in: group)) ?? tag.identifier
            }
            titled.append(Entry(tag: tag, title: title))
        }
        let entries = titled.sorted { lhs, rhs in
            let order = lhs.title.compare(rhs.title, locale: display)
            return order == .orderedSame ? lhs.tag.identifier < rhs.tag.identifier : order == .orderedAscending
        }
        let index = Dictionary(
            uniqueKeysWithValues: entries.enumerated().map { ($0.element.tag.identifier, $0.offset) })

        // The variant a bare language name such as "English" means: the one the user prefers,
        // else the one Foundation calls the language's default, else the first.
        var primary: [String: LanguageTag] = [:]
        for (code, group) in byCode {
            let preferredMatch = preferredTags.lazy.compactMap { wanted in
                wanted.code == code ? bestMatch(for: wanted, in: group) : nil
            }.first
            let standard = LanguageTag(code)
            primary[code] = preferredMatch ?? group.first { $0 == standard } ?? group.first
        }

        var names: [String: LanguageTag] = [:]
        func add(_ name: String?, _ tag: LanguageTag) {
            guard let name else { return }
            let key = folded(name)
            if !key.isEmpty, names[key] == nil { names[key] = tag }
        }
        let userLocale = preferred.first.map { Locale(identifier: $0) }
        for locale in [userLocale, Locale(identifier: "en"), display].compactMap(\.self) {
            for tag in tags {
                let group = byCode[tag.code] ?? [tag]
                if group.count > 1 {
                    add(locale.localizedString(forIdentifier: variantIdentifier(tag, in: group)), tag)
                }
            }
            for tag in tags where primary[tag.code] == tag {
                add(locale.localizedString(forLanguageCode: tag.code), tag)
            }
        }

        let english = primary["en"]
        let automatic = preferredTags.lazy.compactMap { wanted in bestMatch(for: wanted, in: byCode[wanted.code] ?? [])
        }
        .first
        return LanguageCatalog(
            entries: entries, automaticTarget: automatic ?? english ?? entries.first?.tag, english: english,
            display: display, indexByIdentifier: index, languagesByName: names, primaryByCode: primary)
    }

    // MARK: Lookups

    /// The entry for a stored identifier, if the engine offers that language.
    func entry(_ identifier: String) -> Entry? {
        indexByIdentifier[identifier].map { entries[$0] }
    }

    /// The language a typed name means, such as "french", "Französisch" or "chinese simplified".
    /// Nil for a name the catalog does not know.
    func language(named name: some StringProtocol) -> LanguageTag? {
        guard name.utf8.count <= Self.maximumNameBytes else { return nil }
        return languagesByName[Self.folded(name)]
    }

    /// The offered language closest to a tag: the same language in the same script, in the same
    /// region when the engine has it, else the variant a bare name means. Nil when the engine
    /// offers no such language.
    func bestMatch(for tag: LanguageTag) -> LanguageTag? {
        let candidates = entries.lazy.map(\.tag).filter { $0.isSameLanguage(as: tag) }
        if let exact = candidates.first(where: { $0 == tag || $0.region == tag.region }) { return exact }
        if let primary = primaryByCode[tag.code], primary.isSameLanguage(as: tag) { return primary }
        return candidates.first
    }

    /// What a stored setting means: an offered language, or Automatic for an empty value or a
    /// language the engine no longer offers.
    func resolve(_ stored: String) -> LanguageTag? {
        guard !stored.isEmpty else { return automaticTarget }
        return entry(stored)?.tag ?? bestMatch(for: LanguageTag(stored)) ?? automaticTarget
    }

    /// Like ``resolve(_:)`` for a setting whose empty value means none.
    func resolveOptional(_ stored: String) -> LanguageTag? {
        stored.isEmpty ? nil : entry(stored)?.tag ?? bestMatch(for: LanguageTag(stored))
    }

    /// The language a recognizer's guesses point to.
    func source(from guesses: [LanguageGuess]) -> Source {
        guard let first = guesses.first else { return .unknown }
        if let tag = bestMatch(forRecognized: first.identifier) { return .supported(tag) }
        for guess in guesses.dropFirst() where guess.probability >= Self.secondGuessShare * first.probability {
            if let tag = bestMatch(forRecognized: guess.identifier) { return .supported(tag) }
        }
        return .unsupported(first.identifier)
    }

    /// The offered language a recognizer means. A recognizer names no region, so "en" means the
    /// English the user prefers, not the one Foundation would add.
    func bestMatch(forRecognized identifier: String) -> LanguageTag? {
        let tag = LanguageTag(identifier)
        if Locale.Language(identifier: identifier).region == nil, let primary = primaryByCode[tag.code],
            primary.isSameLanguage(as: tag)
        {
            return primary
        }
        return bestMatch(for: tag)
    }

    /// The name of a language, for titles and messages.
    func title(of tag: LanguageTag) -> String {
        entry(tag.identifier)?.title ?? display.localizedString(forLanguageCode: tag.code) ?? tag.identifier
    }

    /// The name of a language the recognizer named, such as "Icelandic" for "is".
    func title(ofRecognized identifier: String) -> String {
        display.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: Helpers

    /// Lowercased, without accents, width or punctuation, with single spaces between words, so
    /// "Chinese, Simplified" and "chinese simplified" are the same name.
    static func folded(_ name: some StringProtocol) -> String {
        let plain = String(name).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var pendingSpace = false
        for character in plain {
            if character.isLetter || character.isNumber {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// The identifier that names one variant among languages with the same code: the script when
    /// it tells them apart, as for Simplified and Traditional Chinese, else the region, as for
    /// British and American English.
    static func variantIdentifier(_ tag: LanguageTag, in group: [LanguageTag]) -> String {
        let sameScript = group.filter { $0.script == tag.script }
        if sameScript.count == 1, !tag.script.isEmpty { return tag.code + "-" + tag.script }
        if group.allSatisfy({ $0.script == tag.script }), !tag.region.isEmpty { return tag.code + "-" + tag.region }
        return tag.identifier
    }

    /// The tag in `group` closest to `wanted`: the same identifier, else the same script and
    /// region, else the same script. Nil when no tag has the same language and script.
    static func bestMatch(for wanted: LanguageTag, in group: [LanguageTag]) -> LanguageTag? {
        let candidates = group.filter { $0.isSameLanguage(as: wanted) }
        return candidates.first { $0 == wanted } ?? candidates.first { $0.region == wanted.region }
            ?? candidates.first
    }
}
