import Contacts
import Foundation
import Synchronization

/// The user's contacts, through `CNContactStore`.
///
/// It runs only in the app, never in a test or a scenario: it reads personal data. Three rules keep
/// it from surprising anyone:
///
/// - Every read first checks `CNContactStore.authorizationStatus(for:)`, which never prompts, and
///   throws ``PeopleError/accessMissing`` unless access is granted. A store used on a background
///   thread before access was decided would raise the system prompt and wait for it, so nothing
///   here reads before that check.
/// - It asks only for the keys the feature shows: names, organisation, job, phone numbers, email
///   addresses, postal addresses, the birthday and whether a photo exists. Notes are never read.
///   The photo is read one card at a time, for the detail pane.
/// - Reads run in `@concurrent` functions, off the main thread.
nonisolated final class LiveContacts: PeopleService {
    /// `CNContactStore` documents itself as thread safe, so one store serves every thread. Apple
    /// recommends one store per app, and the store must stay alive for its change notification
    /// to arrive.
    private final class SharedStore: @unchecked Sendable {
        let store = CNContactStore()
    }

    /// Made on the first read, after the access check, so making the feature touches nothing.
    private let shared = Mutex<SharedStore?>(nil)

    init() {}

    @concurrent func people() async throws -> [Person] {
        let store = try readableStore()
        let request = CNContactFetchRequest(keysToFetch: Self.keys())
        request.unifyResults = true
        var people: [Person] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                people.append(Self.person(from: contact))
            }
        } catch {
            throw Self.peopleError(error)
        }
        try Task.checkCancellation()
        return people
    }

    @concurrent func photo(of id: String) async throws -> Data? {
        let store = try readableStore()
        do {
            let keys = [CNContactThumbnailImageDataKey as any CNKeyDescriptor]
            return try store.unifiedContact(withIdentifier: id, keysToFetch: keys).thumbnailImageData
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        } catch {
            throw Self.peopleError(error)
        }
    }

    /// Listens for `CNContactStoreDidChange`. Adding the observer reads no contacts and makes no
    /// store: the feature asks for this only after a read succeeded, which made the store.
    func storeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil
        ) { _ in
            continuation.yield()
        }
        let token = ObserverToken(observer)
        continuation.onTermination = { _ in
            NotificationCenter.default.removeObserver(token.observer)
        }
        return stream
    }

    // MARK: - Private

    /// Holds the observer for its removal. Notification center tokens are opaque objects that the
    /// center accepts from any thread.
    private final class ObserverToken: @unchecked Sendable {
        let observer: any NSObjectProtocol

        init(_ observer: any NSObjectProtocol) {
            self.observer = observer
        }
    }

    /// The shared store, once macOS says the app may read contacts. The check never prompts.
    private func readableStore() throws -> CNContactStore {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw PeopleError.accessMissing
        }
        let box = shared.withLock { current -> SharedStore in
            if let existing = current { return existing }
            let made = SharedStore()
            current = made
            return made
        }
        return box.store
    }

    /// The keys the feature shows, and those the name formatter needs. Nothing else.
    private static func keys() -> [any CNKeyDescriptor] {
        let names: [String] = [
            CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey, CNContactPhoneticGivenNameKey,
            CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneticOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
            CNContactImageDataAvailableKey,
        ]
        return names.map { $0 as any CNKeyDescriptor } + [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactFormatter.descriptorForRequiredKeysForNameOrder,
        ]
    }

    private static func person(from contact: CNContact) -> Person {
        var person = Person(id: contact.identifier)
        person.kind = contact.contactType == .organization ? .organization : .person
        person.namePrefix = contact.namePrefix
        person.givenName = contact.givenName
        person.middleName = contact.middleName
        person.familyName = contact.familyName
        person.nameSuffix = contact.nameSuffix
        person.nickname = contact.nickname
        person.phoneticGivenName = contact.phoneticGivenName
        person.phoneticMiddleName = contact.phoneticMiddleName
        person.phoneticFamilyName = contact.phoneticFamilyName
        person.organization = contact.organizationName
        person.phoneticOrganization = contact.phoneticOrganizationName
        person.department = contact.departmentName
        person.jobTitle = contact.jobTitle
        person.formattedName = CNContactFormatter.string(from: contact, style: .fullName)
        switch CNContactFormatter.nameOrder(for: contact) {
        case .familyNameFirst: person.nameOrder = .familyFirst
        case .givenNameFirst: person.nameOrder = .givenFirst
        default: person.nameOrder = nil
        }
        person.phones = contact.phoneNumbers.map { LabeledValue(label($0.label), $0.value.stringValue) }
        person.emails = contact.emailAddresses.map { LabeledValue(label($0.label), $0.value as String) }
        person.addresses = contact.postalAddresses.map { labeled in
            let address = labeled.value
            return PostalAddress(
                label: label(labeled.label), street: address.street, city: address.city, state: address.state,
                postalCode: address.postalCode, country: address.country,
                formatted: CNPostalAddressFormatter.string(from: address, style: .mailingAddress))
        }
        if let birthday = contact.birthday, let day = birthday.day, let month = birthday.month,
            (1...31).contains(day), (1...12).contains(month)
        {
            let year = birthday.year.flatMap { (1...9999).contains($0) ? $0 : nil }
            person.birthday = Birthday(day: day, month: month, year: year)
        }
        person.hasPhoto = contact.imageDataAvailable
        return person
    }

    /// The label as Contacts shows it, such as "mobile" for the store's coded label.
    private static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private static func peopleError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? CNError, error.code == .authorizationDenied { return PeopleError.accessMissing }
        return PeopleError.unreadable
    }
}
