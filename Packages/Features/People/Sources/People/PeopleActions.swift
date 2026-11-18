import Foundation
import Kit

/// Makes a person's actions from the row's ID: only the actions the person has something for,
/// with the one the user chose for Return first. A person with several numbers, addresses or
/// email addresses gets a submenu for each action, with one entry per value.
///
/// Every reaching action opens a standard URL through the workspace service. Nothing here reads
/// the store: the person comes from the directory's last read.
@MainActor final class PeopleActions {
    /// Action IDs, stable for tests and for the Return setting.
    nonisolated enum ID {
        static let call = "call"
        static let message = "message"
        static let email = "email"
        static let faceTime = "facetime"
        static let faceTimeAudio = "facetime-audio"
        static let openAddressInMaps = "open-address-in-maps"
        static let openInContacts = "open-in-contacts"
        static let copyName = "copy-name"
        static let copyPhone = "copy-phone"
        static let copyEmail = "copy-email"
        static let copyAddress = "copy-address"
        static let largeTypePhone = "large-type-phone"
    }

    private let directory: PeopleDirectory
    private let settings: FeatureSettings

    init(directory: PeopleDirectory, settings: FeatureSettings) {
        self.directory = directory
        self.settings = settings
    }

    /// The row's actions. A person the directory no longer knows, such as a row root search kept
    /// from before access went away, offers Open in Contacts only.
    func actions(for row: Row) -> [Action] {
        guard let person = directory.person(id: row.id.key) else {
            return [openInContacts(id: row.id.key)].compactMap(\.self)
        }
        return actions(for: person)
    }

    func actions(for person: Person) -> [Action] {
        let phones = Self.unique(person.phones) { ContactLinks.comparableDigits($0.value) }
        let callable = phones.filter { ContactLinks.call($0.value) != nil }
        let emails = Self.unique(person.emails.filter { ContactLinks.emailAddress($0.value) != nil }) {
            ($0.value.trimmingCharacters(in: .whitespaces)).lowercased()
        }
        let addresses = Self.unique(person.addresses.filter { !$0.isEmpty }) { $0.singleLine }

        var actions: [Action] = []
        if !callable.isEmpty {
            actions.append(call(callable))
            actions.append(message(callable))
        }
        if !emails.isEmpty { actions.append(email(emails)) }
        let faceTimeHandles = callable + emails
        if !faceTimeHandles.isEmpty {
            actions.append(faceTime(faceTimeHandles, audioOnly: false))
            actions.append(faceTime(faceTimeHandles, audioOnly: true))
        }
        let mappable = addresses.filter { ContactLinks.maps($0) != nil }
        if !mappable.isEmpty { actions.append(maps(mappable)) }
        if let open = openInContacts(id: person.id) { actions.append(open) }
        if !phones.isEmpty { actions.append(largeType(phones)) }

        let section = Strings.Actions.copySection
        actions.append(
            Action.copy(PersonName.title(of: person), title: Strings.Actions.copyName, hud: Strings.Actions.copiedName)
                .with(id: ID.copyName).with(shortcut: .copy).with(section: section))
        if !phones.isEmpty { actions.append(copy(phones, kind: .phone).with(section: section)) }
        if !emails.isEmpty { actions.append(copy(emails, kind: .email).with(section: section)) }
        if !addresses.isEmpty { actions.append(copyAddress(addresses).with(section: section)) }

        let preferred = settings[PeopleSettings.primaryAction].actionID
        let first =
            actions.firstIndex { $0.id == preferred } ?? actions.firstIndex { $0.id == ID.openInContacts } ?? 0
        if first > 0 {
            actions.insert(actions.remove(at: first).with(section: nil), at: 0)
        }
        return actions
    }

    // MARK: - Reaching

    private func call(_ phones: [LabeledValue]) -> Action {
        oneOrMany(phones, title: Strings.Actions.call, id: ID.call, icon: .symbol("phone")) { phone in
            { context in
                guard let url = ContactLinks.call(phone.value) else { throw ActionFailure(Strings.Failures.call) }
                let app = context.settings[PeopleSettings.callApp]
                try await Self.reach(Strings.Failures.call, in: context) { workspace in
                    if app.isEmpty {
                        try await workspace.open(url)
                    } else {
                        try await workspace.open([url], withApplication: app)
                    }
                }
                return .close()
            }
        }
    }

    private func message(_ phones: [LabeledValue]) -> Action {
        oneOrMany(phones, title: Strings.Actions.message, id: ID.message, icon: .symbol("message")) { phone in
            Self.opening(ContactLinks.message(phone.value), failure: Strings.Failures.message)
        }
    }

    private func email(_ emails: [LabeledValue]) -> Action {
        oneOrMany(emails, title: Strings.Actions.email, id: ID.email, icon: .symbol("envelope")) { email in
            Self.opening(ContactLinks.email(email.value), failure: Strings.Failures.email)
        }
    }

    private func faceTime(_ handles: [LabeledValue], audioOnly: Bool) -> Action {
        oneOrMany(
            handles, title: audioOnly ? Strings.Actions.faceTimeAudio : Strings.Actions.faceTime,
            id: audioOnly ? ID.faceTimeAudio : ID.faceTime, icon: .symbol(audioOnly ? "phone.badge.waveform" : "video")
        ) { handle in
            Self.opening(ContactLinks.faceTime(handle.value, audioOnly: audioOnly), failure: Strings.Failures.faceTime)
        }
    }

    private func maps(_ addresses: [PostalAddress]) -> Action {
        let values = addresses.map { LabeledValue($0.label, $0.singleLine) }
        return oneOrMany(values, title: Strings.Actions.openInMaps, id: ID.openAddressInMaps, icon: .symbol("map")) {
            value in
            let address = addresses.first { $0.singleLine == value.value }
            return Self.opening(address.flatMap(ContactLinks.maps), failure: Strings.Failures.maps)
        }
    }

    private func openInContacts(id: String) -> Action? {
        guard let url = ContactLinks.contactsCard(id) else { return nil }
        return Action(
            Strings.Actions.openInContacts, id: ID.openInContacts, icon: .symbol("person.crop.square"),
            shortcut: .open, run: Self.opening(url, failure: Strings.Failures.contacts))
    }

    /// Shows a number across the screen, to read it out or dial it on another phone. Command-L, as
    /// the host's own Show in Large Type.
    private func largeType(_ phones: [LabeledValue]) -> Action {
        oneOrMany(
            phones, title: Strings.Actions.showPhoneInLargeType, id: ID.largeTypePhone,
            icon: .symbol("textformat.size")
        ) { phone in
            { _ in .showLargeType(phone.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.with(shortcut: .largeType)
    }

    // MARK: - Copying

    private enum CopyKind {
        case phone
        case email
    }

    private func copy(_ values: [LabeledValue], kind: CopyKind) -> Action {
        let title = kind == .phone ? Strings.Actions.copyPhone : Strings.Actions.copyEmail
        let hud = kind == .phone ? Strings.Actions.copiedPhone : Strings.Actions.copiedEmail
        let id = kind == .phone ? ID.copyPhone : ID.copyEmail
        return oneOrMany(values, title: title, id: id, icon: .symbol("doc.on.doc")) { value in
            { context in
                await context.pasteboard.copy(value.value.trimmingCharacters(in: .whitespacesAndNewlines))
                return .close(hud: HUD(hud))
            }
        }
    }

    private func copyAddress(_ addresses: [PostalAddress]) -> Action {
        let values = addresses.map { LabeledValue($0.label, $0.lines.joined(separator: "\n")) }
        return oneOrMany(values, title: Strings.Actions.copyAddress, id: ID.copyAddress, icon: .symbol("doc.on.doc")) {
            value in
            { context in
                await context.pasteboard.copy(value.value)
                return .close(hud: HUD(Strings.Actions.copiedAddress))
            }
        }
    }

    // MARK: - Helpers

    /// One action for one value, or a submenu with an entry per value, titled with its label.
    private func oneOrMany(
        _ values: [LabeledValue], title: String, id: String, icon: Icon,
        handler: (LabeledValue) -> Action.Handler
    ) -> Action {
        if values.count == 1, let value = values.first {
            return Action(title, id: id, icon: icon, run: handler(value))
        }
        let entries = values.enumerated().map { index, value in
            Action(
                Strings.Actions.entry(label: value.label, value: value.value), id: "\(id).\(index)", run: handler(value)
            )
        }
        return .submenu(title, id: id, icon: icon) { _ in entries }
    }

    /// A handler that opens the URL and closes the panel.
    private static func opening(_ url: URL?, failure: String) -> Action.Handler {
        { context in
            guard let url else { throw ActionFailure(failure) }
            try await reach(failure, in: context) { try await $0.open(url) }
            return .close()
        }
    }

    /// Runs an open through the workspace service and names what failed in words the user reads.
    private static func reach(
        _ failure: String, in context: ActionContext, _ body: (any WorkspaceService) async throws -> Void
    ) async throws {
        context.dismiss()
        do {
            try await body(context.workspace)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionFailure(failure, message: Strings.Failures.openMessage)
        }
    }

    /// The values in order, each kept once, compared by `key`.
    private static func unique<Value>(_ values: [Value], by key: (Value) -> String) -> [Value] {
        var seen = Set<String>()
        return values.filter { seen.insert(key($0)).inserted }
    }
}
