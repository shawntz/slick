import Foundation
import Kit

/// What the detail pane shows for a person: the photo, then the name, work, phone numbers, email
/// addresses, postal addresses and birthday, each group set apart by a rule.
nonisolated enum PersonDetail {
    static func make(_ person: Person, photo: Data?, locale: Locale) -> Detail {
        let title = PersonName.title(of: person)
        var groups: [[MetadataItem]] = []

        var about: [MetadataItem] = []
        let name = PersonName.fullName(of: person)
        if !name.isEmpty, name != title { about.append(.label(Strings.Detail.name, value: name)) }
        let phonetic = PersonName.phoneticName(of: person)
        if !phonetic.isEmpty { about.append(.label(Strings.Detail.phoneticName, value: phonetic)) }
        add(person.nickname, as: Strings.Detail.nickname, to: &about)
        if !PersonName.titleIsOrganization(person) { add(person.organization, as: Strings.Detail.company, to: &about) }
        add(person.jobTitle, as: Strings.Detail.jobTitle, to: &about)
        add(person.department, as: Strings.Detail.department, to: &about)
        groups.append(about)

        groups.append(
            person.phones.compactMap { phone in
                let value = PersonName.oneLine(phone.value)
                return value.isEmpty
                    ? nil : .label(labelTitle(phone.label, otherwise: Strings.Detail.phone), value: value)
            })
        groups.append(
            person.emails.compactMap { email in
                let value = PersonName.oneLine(email.value)
                return value.isEmpty
                    ? nil : .label(labelTitle(email.label, otherwise: Strings.Detail.email), value: value)
            })
        groups.append(
            person.addresses.compactMap { address in
                address.isEmpty
                    ? nil
                    : .label(
                        labelTitle(address.label, otherwise: Strings.Detail.address),
                        value: address.lines.joined(separator: "\n"))
            })
        if let birthday = person.birthday, let text = format(birthday, locale: locale) {
            groups.append([.label(Strings.Detail.birthday, value: text)])
        }

        var metadata: [MetadataItem] = []
        for group in groups where !group.isEmpty {
            if !metadata.isEmpty { metadata.append(.separator) }
            metadata += group
        }
        return Detail(photo.map { .image(.data($0)) }, metadata: metadata)
    }

    /// A label as a heading: "mobile" becomes "Mobile", and "iPhone" stays as it is. An empty label
    /// becomes the field's name.
    static func labelTitle(_ label: String, otherwise: String) -> String {
        let label = PersonName.oneLine(label)
        guard let first = label.first else { return otherwise }
        let second = label.dropFirst().first
        guard first.isLowercase, second.map({ !$0.isUppercase }) ?? true else { return label }
        return first.uppercased() + label.dropFirst()
    }

    /// The birthday in the locale's style, with the year when the card has one.
    static func format(_ birthday: Birthday, locale: Locale) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // A leap year stands in for a missing one, so 29 February still makes a date.
        let components = DateComponents(year: birthday.year ?? 2000, month: birthday.month, day: birthday.day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(birthday.year == nil ? "MMMMd" : "yMMMMd")
        return formatter.string(from: date)
    }

    private static func add(_ value: String, as label: String, to items: inout [MetadataItem]) {
        let value = PersonName.oneLine(value)
        if !value.isEmpty { items.append(.label(label, value: value)) }
    }
}
