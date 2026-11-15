import Kit

/// The feature's settings, stored as `snippets.<name>`.
nonisolated enum SnippetsSettings {
    /// Off until the user turns it on, because expansion watches every keystroke.
    static let expansionEnabled = SettingKey("expansionEnabled", default: false)
    static let trigger = SettingKey("trigger", default: ExpansionTrigger.immediately)
    /// Typed before every keyword, such as ";". Empty for none.
    static let keywordPrefix = SettingKey("keywordPrefix", default: "")
    static let expandsWithinWords = SettingKey("expandsWithinWords", default: false)
    /// Bundle IDs of apps where nothing expands. Password managers to begin with, the same ones
    /// clipboard history ignores.
    static let excludedApps = SettingKey(
        "excludedApps",
        default: [
            "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
            "com.bitwarden.desktop", "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.lastpass.LastPass",
        ])
    static let showsInRootSearch = SettingKey("showsInRootSearch", default: true)
    static let order = SettingKey("order", default: SnippetOrder.name)

    /// The settings text expansion depends on. A change to any of them restarts it.
    static let expansionKeys = [
        expansionEnabled.erased, trigger.erased, keywordPrefix.erased, expandsWithinWords.erased, excludedApps.erased,
    ]

    /// The prefix as it is used: white space is never part of a keyword.
    static func prefix(in settings: FeatureSettings) -> String {
        settings[keywordPrefix].filter { !$0.isWhitespace }
    }
}

/// When a typed keyword expands.
nonisolated enum ExpansionTrigger: String, CaseIterable, SettingValue {
    case immediately
    case afterDelimiter = "after-delimiter"

    var title: String {
        switch self {
        case .immediately: Strings.triggerImmediately
        case .afterDelimiter: Strings.triggerAfterDelimiter
        }
    }

    var option: ExpansionOptions.Trigger {
        switch self {
        case .immediately: .immediately
        case .afterDelimiter: .afterDelimiter
        }
    }
}

/// How snippets are ordered inside each section of the list.
nonisolated enum SnippetOrder: String, CaseIterable, SettingValue {
    case name
    case frequency

    var title: String {
        switch self {
        case .name: Strings.orderName
        case .frequency: Strings.orderFrequency
        }
    }
}
