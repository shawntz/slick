import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Titles use title case, as macOS menus do, and end without a full stop. Everything else is a
/// plain sentence that says what will happen.
nonisolated enum Strings {
    static let featureName = "Contacts"
    static let summary = "Find a person in Contacts and call, message, email or FaceTime them."
    static let permissionReason = "Read your contacts on this Mac, so you can find people and reach them from here."

    enum Commands {
        static let search = "Search Contacts"
        static let searchKeywords = ["people", "person", "phone", "email", "address book", "call", "facetime"]
        static let searchPlaceholder = "Search contacts"

        static func fallback(_ text: String) -> String {
            "Search Contacts for \u{201C}\(text)\u{201D}"
        }
    }

    enum Rows {
        static let noName = "No Name"

        /// A job at a company, as the line under a person's name.
        static func jobAt(_ job: String, _ company: String) -> String {
            "\(PersonName.oneLine(job)), \(PersonName.oneLine(company))"
        }
    }

    enum List {
        static let noMatchesTitle = "No Matching Contacts"
        static let emptyTitle = "No Contacts"
        static let emptyMessage = "People you add in the Contacts app show up here."
    }

    enum Access {
        static let offTitle = "Contacts Access Is Off"
        static let offMessage = "Allow access to find people here and in root search."
        static let allow = "Allow Access"
        static let onTitle = "Contacts Access Is On"
        static let restrictedMessage = "A profile on this Mac blocks access to Contacts."

        static var turnOnMessage: String {
            "Turn on \(Brand.name) in System Settings under Privacy & Security, then Contacts, and open Search "
                + "Contacts again."
        }
    }

    enum Actions {
        static let call = "Call"
        static let message = "Message"
        static let email = "Email"
        static let faceTime = "FaceTime"
        static let faceTimeAudio = "FaceTime Audio"
        static let openInMaps = "Open Address in Maps"
        static let openInContacts = "Open in Contacts"
        static let copySection = "Copy"
        static let copyName = "Copy Name"
        static let copyPhone = "Copy Phone Number"
        static let copyEmail = "Copy Email Address"
        static let copyAddress = "Copy Address"
        static let copiedName = "Copied Name"
        static let copiedPhone = "Copied Phone Number"
        static let copiedEmail = "Copied Email Address"
        static let copiedAddress = "Copied Address"

        /// A submenu entry: the value with its label, such as "Mobile: +1 555 010 0101".
        static func entry(label: String, value: String) -> String {
            let value = PersonName.oneLine(value)
            let label = PersonDetail.labelTitle(label, otherwise: "")
            return label.isEmpty ? value : "\(label): \(value)"
        }
    }

    enum Failures {
        static let call = "Could Not Start the Call"
        static let message = "Could Not Open Messages"
        static let email = "Could Not Start the Email"
        static let faceTime = "Could Not Start FaceTime"
        static let maps = "Could Not Open Maps"
        static let contacts = "Could Not Open Contacts"
        static let openMessage = "macOS did not open the link. Check that an app that handles it is installed."
        static let unreadable = "Contacts Could Not Be Read"
        static let unreadableMessage = "Something went wrong while reading Contacts. Try again in a moment."
    }

    enum Detail {
        static let name = "Name"
        static let phoneticName = "Pronunciation"
        static let nickname = "Nickname"
        static let company = "Company"
        static let jobTitle = "Job Title"
        static let department = "Department"
        static let phone = "Phone"
        static let email = "Email"
        static let address = "Address"
        static let birthday = "Birthday"
    }

    enum Settings {
        static let searchSection = "Root Search"
        static let showsInRootSearch = "Show people in root search"
        static let showsInRootSearchInfo =
            "Names, nicknames and companies join the launcher's search index on this Mac once you allow access. "
            + "Phone numbers, email addresses and street addresses stay out of it."

        static let actionsSection = "Actions"
        static let primaryAction = "Return key"
        static let primaryActionInfo = "What Return does on a person. Command-K shows every action."
        static let callApp = "Calls open in"
        static let callAppInfo =
            "When no app is chosen, calls use the app macOS opens phone links with, usually FaceTime."

        static let accessSection = "Access and Privacy"
        static let allowAccess = "Allow Access to Contacts"
        static let allowAccessInfo =
            "Asks macOS for access. If you turned access off before, this opens System Settings, where you can turn it "
            + "back on."

        static var privacyNote: String {
            "\(Brand.name) reads your contacts on this Mac only, keeps them in memory while it runs, and sends "
                + "nothing over the network. The feature writes no name, number or address to disk. Root search learns "
                + "which person you pick for what you type, as it does for apps, and keeps that on this Mac. "
                + "Learning in settings shows it and can erase it."
        }

        static func primaryActionTitle(_ action: PrimaryAction) -> String {
            switch action {
            case .openInContacts: Actions.openInContacts
            case .call: Actions.call
            case .message: Actions.message
            case .email: Actions.email
            case .faceTime: Actions.faceTime
            case .copyPhone: Actions.copyPhone
            case .copyEmail: Actions.copyEmail
            }
        }
    }
}
