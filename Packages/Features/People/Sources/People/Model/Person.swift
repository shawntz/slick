import Foundation

/// One card from the contact store, with only the fields the feature shows.
///
/// The service fills it off the main thread. Labels arrive ready to show, such as "mobile" or
/// "work", and may be empty. Every text field is empty rather than missing, as in the store.
nonisolated struct Person: Hashable, Sendable {
    /// Whether the card is a person or a company. Contacts lets the user mark a card as a company,
    /// and then shows its organisation as its name.
    enum Kind: String, Hashable, Sendable {
        case person
        case organization
    }

    /// The store's identifier. Stable on this Mac, so it is the row key.
    var id: String
    var kind: Kind = .person
    var namePrefix = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nameSuffix = ""
    var nickname = ""
    var phoneticGivenName = ""
    var phoneticMiddleName = ""
    var phoneticFamilyName = ""
    var organization = ""
    var phoneticOrganization = ""
    var department = ""
    var jobTitle = ""
    /// The full name as the system writes it for this person, when the service knows it. Nil means
    /// the feature composes one from the parts.
    var formattedName: String?
    /// The order the name reads in. Nil means the feature infers it from the script.
    var nameOrder: NameOrder?
    var phones: [LabeledValue] = []
    var emails: [LabeledValue] = []
    var addresses: [PostalAddress] = []
    var birthday: Birthday?
    /// True when the card has a photo. The photo itself is read only for the detail pane.
    var hasPhoto = false
}

/// A phone number or an email address with its label.
nonisolated struct LabeledValue: Hashable, Sendable {
    /// Ready to show, such as "mobile". May be empty.
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A postal address with its label.
nonisolated struct PostalAddress: Hashable, Sendable {
    var label = ""
    var street = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""
    /// The address as the system formats it for mail in its country, line by line, when the
    /// service knows it. Nil means the feature composes it from the parts.
    var formatted: String?

    /// The address on several lines, with blank lines and spaces at either end dropped.
    var lines: [String] {
        let text: String
        if let formatted, !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = formatted
        } else {
            let place = [postalCode, city].filter { !$0.isEmpty }.joined(separator: " ")
            text = [street, place, state, country].joined(separator: "\n")
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The address on one line, its lines joined by commas, as Maps and a search field take it.
    var singleLine: String {
        lines.joined(separator: ", ")
    }

    /// True when the address holds nothing to show.
    var isEmpty: Bool { lines.isEmpty }

    /// The size of its text in UTF-8, read without a pass over it.
    var byteCount: Int {
        [street, city, state, postalCode, country, formatted ?? ""].reduce(0) { $0 + $1.utf8.count }
    }
}

/// A birthday. The year is optional in Contacts.
nonisolated struct Birthday: Hashable, Sendable {
    var day: Int
    var month: Int
    var year: Int?
}

/// The order a name reads in.
nonisolated enum NameOrder: String, Hashable, Sendable {
    /// "Ana Lima".
    case givenFirst
    /// "Lima Ana", as Chinese, Japanese, Korean and Hungarian names read.
    case familyFirst
}
