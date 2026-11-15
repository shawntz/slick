import Foundation

/// Builds the URLs that reach a person, with the standard schemes: `tel:` for a call, `sms:` for a
/// message, `facetime:` and `facetime-audio:`, `mailto:`, a Maps link for an address, and the
/// Contacts app's own link to a card. Pure functions: a value people typed goes in, a URL or nil
/// comes out.
nonisolated enum ContactLinks {
    /// A phone number as a dialer takes it.
    struct DialString: Hashable, Sendable {
        /// Digits, with a plus first for an international number.
        var number: String
        /// The extension's digits, dialled after a pause. Nil when there is none.
        var `extension`: String?
    }

    /// Reads a phone number as people write it: with spaces, dashes, dots, slashes and brackets,
    /// a leading plus, digits of any script, letters on a keypad such as 1-800-FLOWERS, and an
    /// extension after "ext", "x", "#", a comma or a semicolon. Nil when the text holds fewer than
    /// three digits, or a star or hash that is not an extension: a dialer treats those as codes,
    /// so the feature offers to copy such a number but not to call it.
    ///
    /// Words are read so that a call never reaches a number the text does not clearly hold. Capitals
    /// after a digit are keypad letters. A word set apart by spaces, such as "mobile", is a note and
    /// is left out, but digits after such a note make the number unclear, as in "555 0100 fax 2".
    /// A word joined to the digits that is not in capitals, as in "1-800-flowers", is unclear too.
    /// An unclear number is offered for copying only.
    static func dialString(_ text: String) -> DialString? {
        // Actions are made on the main thread, so a huge value is turned away before any pass over it.
        guard text.utf8.count <= 400 else { return nil }
        let characters = Array(text.precomposedStringWithCompatibilityMapping)
        guard characters.count <= 100 else { return nil }
        let (main, extensionDigits) = splitExtension(characters)
        var number = ""
        var digitCount = 0
        var word: [Character] = []
        var wordJoinsLeft = false
        var sawNoteAfterDigits = false
        var isUnclear = false
        var previous: Character?
        func endWord(before next: Character?) {
            guard !word.isEmpty else { return }
            let joinsRight = next.map { asciiDigit($0) != nil } ?? false
            if digitCount > 0, word.allSatisfy(\.isUppercase) {
                number.append(contentsOf: word.compactMap(keypadDigit))
            } else if wordJoinsLeft || joinsRight {
                isUnclear = true
            } else if digitCount > 0 {
                sawNoteAfterDigits = true
            }
            word = []
        }
        for character in main {
            if character.isASCII, character.isLetter {
                if word.isEmpty {
                    wordJoinsLeft = digitCount > 0 && previous.map(joinsDigits) == true
                }
                word.append(character)
                previous = character
                continue
            }
            endWord(before: character)
            if let digit = asciiDigit(character) {
                if sawNoteAfterDigits { return nil }
                number.append(digit)
                digitCount += 1
            } else if character == "+" {
                guard number.isEmpty else { return nil }
                number.append("+")
            } else if character == "*" || character == "#" {
                return nil
            }
            previous = character
        }
        endWord(before: nil)
        if isUnclear { return nil }
        let digits = number.filter(\.isNumber)
        guard digits.count >= 3, digits.count <= 20 else { return nil }
        return DialString(number: number, extension: extensionDigits)
    }

    /// A call to the number, with a pause before the extension: `tel:+15550100100,23`.
    static func call(_ phone: String) -> URL? {
        guard let dial = dialString(phone) else { return nil }
        return URL(string: "tel:" + dial.number + (dial.extension.map { "," + $0 } ?? ""))
    }

    /// A message to the number in Messages: `sms:+15550100100`. The extension is left out.
    static func message(_ phone: String) -> URL? {
        guard let dial = dialString(phone) else { return nil }
        return URL(string: "sms:" + dial.number)
    }

    /// A FaceTime call to a phone number or an email address: `facetime:` for video,
    /// `facetime-audio:` for audio only.
    static func faceTime(_ handle: String, audioOnly: Bool) -> URL? {
        let scheme = audioOnly ? "facetime-audio:" : "facetime:"
        if let address = emailAddress(handle) {
            return URL(string: scheme + encode(address, keeping: mailtoKept))
        }
        guard let dial = dialString(handle) else { return nil }
        return URL(string: scheme + dial.number)
    }

    /// A new email to the address in the default mail app: `mailto:ana@example.com`.
    static func email(_ address: String) -> URL? {
        guard let address = emailAddress(address) else { return nil }
        return URL(string: "mailto:" + encode(address, keeping: mailtoKept))
    }

    /// The address in Maps: `maps://?address=...`, every character but letters, digits and
    /// `-._~` percent-encoded, so commas, ampersands and plus signs reach Maps as typed.
    static func maps(_ address: PostalAddress) -> URL? {
        guard address.byteCount <= 4_000 else { return nil }
        let line = address.singleLine
        guard !line.isEmpty, line.count <= 1_000 else { return nil }
        return URL(string: "maps://?address=" + encode(line, keeping: unreserved))
    }

    /// The card in the Contacts app: `addressbook://<identifier>`.
    static func contactsCard(_ id: String) -> URL? {
        guard !id.isEmpty, id.count <= 200 else { return nil }
        return URL(string: "addressbook://" + encode(id, keeping: unreserved.union(CharacterSet(charactersIn: ":"))))
    }

    /// The address with spaces at either end trimmed, when it looks like one: one "@" with text on
    /// both sides, no spaces or control characters inside, at most 254 characters.
    static func emailAddress(_ text: String) -> String? {
        guard text.utf8.count <= 1_000 else { return nil }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard address.count <= 254, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
            !address.unicodeScalars.contains(where: {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            })
        else { return nil }
        return address
    }

    /// The digits of a number, for telling two ways of writing it apart from two numbers.
    static func comparableDigits(_ phone: String) -> String {
        guard let dial = dialString(phone) else { return phone.trimmingCharacters(in: .whitespaces) }
        let digits = dial.number.filter(\.isNumber)
        return digits + (dial.extension.map { "," + $0 } ?? "")
    }

    // MARK: - Private

    /// RFC 3986's unreserved characters.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// What an address may keep unencoded in a `mailto:` or `facetime:` link.
    private static let mailtoKept = unreserved.union(CharacterSet(charactersIn: "@!$'*+"))

    private static func encode(_ text: String, keeping allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Splits a trailing extension off: the digits at the end, when a marker stands before them and
    /// at least three digits before that.
    private static func splitExtension(_ characters: [Character]) -> (main: ArraySlice<Character>, ext: String?) {
        var end = characters.endIndex
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        var start = end
        while start > 0, asciiDigit(characters[start - 1]) != nil { start -= 1 }
        guard start < end, end - start <= 10 else { return (characters[...], nil) }
        let digits = String(characters[start..<end].compactMap(asciiDigit))
        var markerEnd = start
        while markerEnd > 0, characters[markerEnd - 1].isWhitespace || ".:".contains(characters[markerEnd - 1]) {
            markerEnd -= 1
        }
        for marker in extensionMarkers {
            let markerStart = markerEnd - marker.count
            guard markerStart >= 0,
                zip(characters[markerStart..<markerEnd], marker).allSatisfy({ $0.lowercased() == String($1) })
            else { continue }
            // A word marker must not end a word, as "fax" would.
            if marker.first?.isLetter == true, markerStart > 0, characters[markerStart - 1].isLetter { continue }
            let main = characters[..<markerStart]
            guard main.filter({ asciiDigit($0) != nil }).count >= 3 else { continue }
            return (main, digits)
        }
        return (characters[...], nil)
    }

    private static let extensionMarkers = ["extension", "ext", "x", "#", ",", ";"]

    /// True for a character that joins a word to the digits before it: a digit, a dash or a dot.
    private static func joinsDigits(_ character: Character) -> Bool {
        asciiDigit(character) != nil || character == "-" || character == "."
    }

    /// The ASCII digit for a decimal digit of any script.
    private static func asciiDigit(_ character: Character) -> Character? {
        guard character.isNumber, let value = character.wholeNumberValue, (0...9).contains(value),
            character.unicodeScalars.count == 1,
            character.unicodeScalars.first?.properties.numericType == .decimal
        else { return nil }
        return Character(String(value))
    }

    /// The keypad digit for a letter: ABC is 2, and so on to WXYZ, 9.
    private static func keypadDigit(_ letter: Character) -> Character? {
        switch letter.uppercased() {
        case "A", "B", "C": "2"
        case "D", "E", "F": "3"
        case "G", "H", "I": "4"
        case "J", "K", "L": "5"
        case "M", "N", "O": "6"
        case "P", "Q", "R", "S": "7"
        case "T", "U", "V": "8"
        case "W", "X", "Y", "Z": "9"
        default: nil
        }
    }
}
