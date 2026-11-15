import Kit

/// The feature's settings, stored as `quicklinks.<name>`. `nonisolated`, so code off the main actor
/// can read them.
nonisolated enum QuicklinksSettings {
    /// The ID of the quicklink that Search the Web uses and root offers first when nothing matches.
    static let defaultSearch = SettingKey("defaultSearch", default: DefaultSearches.defaultEngineID)
    /// Offer the default search engine, and quicklinks marked as fallbacks, when nothing matches.
    static let offersFallbacks = SettingKey("offersFallbacks", default: true)
    /// Offer to open a typed web address.
    static let detectsAddresses = SettingKey("detectsAddresses", default: true)

    /// Every key, for one watch over all of them.
    static let all: [AnySettingKey] = [defaultSearch.erased, offersFallbacks.erased, detectsAddresses.erased]
}
