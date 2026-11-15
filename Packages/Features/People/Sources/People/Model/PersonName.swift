import Foundation

/// How a person is named and found: the title a row shows, what it says under it, and the extra
/// words search matches. Pure functions, so tests cover every case without a store.
nonisolated enum PersonName {
    /// The name a row shows. Never empty: a card with no name shows its nickname, its
    /// organisation, its first email address or phone number, in that order, and then a fixed
    /// title.
    static func title(of person: Person) -> String {
        title(of: person, name: fullName(of: person))
    }

    /// The title, given the full name already worked out.
    static func title(of person: Person, name: String) -> String {
        if person.kind == .organization, let organization = nonEmpty(person.organization) {
            return oneLine(organization)
        }
        if !name.isEmpty { return name }
        if let nickname = nonEmpty(person.nickname) { return oneLine(nickname) }
        if let organization = nonEmpty(person.organization) { return oneLine(organization) }
        if let email = person.emails.lazy.compactMap({ nonEmpty($0.value) }).first { return oneLine(email) }
        if let phone = person.phones.lazy.compactMap({ nonEmpty($0.value) }).first { return oneLine(phone) }
        return Strings.Rows.noName
    }

    /// True when the title is the organisation's name rather than a person's.
    static func titleIsOrganization(_ person: Person) -> Bool {
        titleIsOrganization(person, name: fullName(of: person))
    }

    /// The same, given the full name already worked out.
    static func titleIsOrganization(_ person: Person, name: String) -> Bool {
        guard nonEmpty(person.organization) != nil else { return false }
        if person.kind == .organization { return true }
        return name.isEmpty && nonEmpty(person.nickname) == nil
    }

    /// The person's full name: the system's form when the service gave one, else the parts in the
    /// name's order. Empty when the card has no name parts.
    static func fullName(of person: Person) -> String {
        if let formatted = nonEmpty(person.formattedName) { return oneLine(formatted) }
        return oneLine(
            joined(
                order(of: person), prefix: person.namePrefix, given: person.givenName, middle: person.middleName,
                family: person.familyName, suffix: person.nameSuffix))
    }

    /// The phonetic name, such as the reading of a Japanese name, in the name's order.
    static func phoneticName(of person: Person) -> String {
        oneLine(
            joined(
                order(of: person), prefix: "", given: person.phoneticGivenName, middle: person.phoneticMiddleName,
                family: person.phoneticFamilyName, suffix: ""))
    }

    /// The order the person's name reads in: the service's answer, else family name first when
    /// the name is written in Han, kana or Hangul, else given name first.
    static func order(of person: Person) -> NameOrder {
        if let order = person.nameOrder { return order }
        let parts = person.familyName + person.givenName
        return parts.unicodeScalars.contains(where: isEastAsian) ? .familyFirst : .givenFirst
    }

    /// The line under the title: what tells two people with the same name apart. For a person,
    /// the job and organisation; for an organisation or a card without one, the first email
    /// address or phone number that is not already the title.
    static func subtitle(of person: Person, title: String) -> String? {
        subtitle(of: person, title: title, name: fullName(of: person))
    }

    /// The same, given the full name already worked out.
    static func subtitle(of person: Person, title: String, name: String) -> String? {
        if !titleIsOrganization(person, name: name) {
            let job = nonEmpty(person.jobTitle)
            let organization = nonEmpty(person.organization)
            switch (job, organization) {
            case (let job?, let organization?): return Strings.Rows.jobAt(job, organization)
            case (nil, let organization?): return oneLine(organization)
            default: break
            }
        }
        let contacts = (person.emails + person.phones).lazy.compactMap { nonEmpty($0.value) }
        return contacts.first { $0 != title }.map(oneLine)
    }

    /// Words root search matches besides the title: the nickname, the organisation, the phonetic
    /// name, and Latin spellings of names written in other scripts, so "ivan" finds "Иван".
    /// Never phone numbers or addresses: root search keeps names only.
    static func rootKeywords(of person: Person, title: String) -> [String] {
        rootKeywords(of: person, title: title, name: fullName(of: person))
    }

    /// The same, given the full name already worked out. `speller` spells words in Latin letters,
    /// and may remember them across people.
    static func rootKeywords(
        of person: Person, title: String, name: String, speller: LatinSpeller = LatinSpeller()
    ) -> [String] {
        var words: [String] = []
        func add(_ text: String?) {
            guard let text else { return }
            let line = oneLine(text)
            guard !line.isEmpty, line != title, !words.contains(line) else { return }
            words.append(line)
        }
        let phonetic = phoneticName(of: person)
        add(name)
        add(person.nickname)
        add(person.organization)
        add(phonetic)
        add(person.phoneticOrganization)
        // The name is spelled part by part, since family and given names repeat across people.
        let parts =
            order(of: person) == .familyFirst
            ? [person.familyName, person.givenName, person.middleName]
            : [person.givenName, person.middleName, person.familyName]
        add(speller.spell(parts))
        let phoneticParts =
            order(of: person) == .familyFirst
            ? [person.phoneticFamilyName, person.phoneticGivenName, person.phoneticMiddleName]
            : [person.phoneticGivenName, person.phoneticMiddleName, person.phoneticFamilyName]
        add(speller.spell(phoneticParts))
        add(speller.spell([person.nickname]))
        add(speller.spell([person.organization]))
        if title != name { add(speller.spell([title])) }
        return words
    }

    /// Words the Search Contacts list matches besides the title: everything root search matches,
    /// plus the job, department, email addresses and phone numbers, with the numbers also as bare
    /// digits so "5550100" finds "+1 (555) 0100".
    static func listKeywords(of person: Person, title: String, rootKeywords: [String]? = nil) -> [String] {
        var words = rootKeywords ?? self.rootKeywords(of: person, title: title)
        func add(_ text: String) {
            let text = oneLine(text)
            guard !text.isEmpty, text != title, !words.contains(text) else { return }
            words.append(text)
        }
        add(person.jobTitle)
        add(person.department)
        for email in person.emails { add(email.value) }
        for phone in person.phones {
            add(phone.value)
            add(String(phone.value.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init)))
        }
        return words
    }

    /// A key that sorts names as people expect: case and accents ignored.
    static func sortKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The text in Latin letters when it holds letters of another script, such as Cyrillic, Greek,
    /// Han, kana or Hangul. Nil for text that is already Latin, so most names cost nothing.
    static func latinSpelling(of text: String) -> String? {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }), text.unicodeScalars.contains(where: isOtherScriptLetter) else {
            return nil
        }
        guard let latin = text.applyingTransform(.toLatin, reverse: false) else { return nil }
        let trimmed = latin.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == text ? nil : trimmed
    }

    /// The text on one line: line breaks and other control characters become spaces, and runs of
    /// spaces become one.
    static func oneLine(_ text: String) -> String {
        if isOneLine(text) { return text }
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace
                || character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control })
            {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Private

    /// True when the text has no control characters, no white space but single spaces, and no space
    /// at either end. Reads bytes for ASCII text, which most names are.
    private static func isOneLine(_ text: String) -> Bool {
        var previousWasSpace = true
        for byte in text.utf8 {
            if byte >= 0x80 { return isOneLineUnicode(text) }
            if byte < 0x20 || byte == 0x7F { return false }
            let isSpace = byte == 0x20
            if isSpace, previousWasSpace { return false }
            previousWasSpace = isSpace
        }
        return text.isEmpty || !previousWasSpace
    }

    private static func isOneLineUnicode(_ text: String) -> Bool {
        var previousWasSpace = true
        for scalar in text.unicodeScalars {
            if scalar == " " {
                if previousWasSpace { return false }
                previousWasSpace = true
                continue
            }
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control { return false }
            previousWasSpace = false
        }
        return !previousWasSpace
    }

    private static func joined(
        _ order: NameOrder, prefix: String, given: String, middle: String, family: String, suffix: String
    ) -> String {
        let parts: [String]
        switch order {
        case .givenFirst: parts = [prefix, given, middle, family, suffix]
        case .familyFirst: parts = [prefix, family, given, middle, suffix]
        }
        return parts.filter { !isBlank($0) }.joined(separator: " ")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !isBlank(text) else { return nil }
        return text
    }

    /// True for text that shows nothing: white space, control characters and invisible format
    /// characters such as a zero-width space. Stops at the first other character, so a name costs
    /// one step.
    private static func isBlank(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return !scalar.properties.isWhitespace && category != .control && category != .format
        }
    }

    /// Han, kana and Hangul: scripts whose names read family name first.
    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
            0xF900...0xFAFF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    /// A letter beyond the Latin blocks.
    private static func isOtherScriptLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x024F && scalar.properties.isAlphabetic
            && !(0x1E00...0x1EFF).contains(scalar.value)
    }
}

/// Spells words of other scripts in Latin letters and remembers each word, so a family name shared
/// by many people is spelled once. One speller serves one task: it is not shared between threads.
nonisolated final class LatinSpeller {
    private var words: [String: String] = [:]

    init() {}

    /// The texts joined by spaces and spelled in Latin letters, word by word. Nil when every word
    /// is already Latin, which costs one pass over the bytes for most names.
    func spell(_ texts: [String]) -> String? {
        let parts = texts.filter { !$0.isEmpty }
        guard parts.contains(where: { !$0.utf8.allSatisfy { $0 < 0x80 } }) else { return nil }
        var changed = false
        var spelled: [String] = []
        for part in parts {
            for word in part.split(whereSeparator: \.isWhitespace) {
                let word = String(word)
                if let known = words[word] {
                    changed = changed || known != word
                    spelled.append(known)
                    continue
                }
                let latin = PersonName.latinSpelling(of: word) ?? word
                words[word] = latin
                changed = changed || latin != word
                spelled.append(latin)
            }
        }
        return changed ? spelled.joined(separator: " ") : nil
    }
}
