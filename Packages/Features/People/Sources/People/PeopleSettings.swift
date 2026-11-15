import Kit

/// The feature's settings. `nonisolated`, so code off the main actor can read them too.
nonisolated enum PeopleSettings {
    /// Whether people join root search by name. On by default, as in Alfred; it has an effect only
    /// once the user allowed access to Contacts.
    static let showsInRootSearch = SettingKey("showsInRootSearch", default: true)
    /// What Return does on a person. Opening the card is the default: it reaches no one by itself.
    static let primaryAction = SettingKey("primaryAction", default: PrimaryAction.openInContacts)
    /// The bundle ID of the app that places calls. Empty uses the app macOS opens `tel:` links
    /// with, usually FaceTime.
    static let callApp = SettingKey("callApp", default: "")
}

/// What Return does on a person.
nonisolated enum PrimaryAction: String, SettingValue, CaseIterable, Sendable {
    case openInContacts
    case call
    case message
    case email
    case faceTime
    case copyPhone
    case copyEmail

    /// The ID of the action it puts first.
    var actionID: String {
        switch self {
        case .openInContacts: PeopleActions.ID.openInContacts
        case .call: PeopleActions.ID.call
        case .message: PeopleActions.ID.message
        case .email: PeopleActions.ID.email
        case .faceTime: PeopleActions.ID.faceTime
        case .copyPhone: PeopleActions.ID.copyPhone
        case .copyEmail: PeopleActions.ID.copyEmail
        }
    }
}
