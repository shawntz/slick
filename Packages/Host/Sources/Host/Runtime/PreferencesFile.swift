import Foundation
import Kit
import KitHosting

/// What `preferences.json` holds: every preference by raw item ID.
///
/// Decoding tolerates missing keys and drops entries whose ID does not parse, so a file written by
/// an older version, or edited by hand, still loads.
nonisolated struct PreferencesFile: Codable, Sendable, Equatable {
    var aliases: [String: String] = [:]
    var hotkeys: [String: KeyCombo] = [:]
    var favorites: [String] = []
    /// The user's feature switches. A feature without one follows its manifest.
    var features: [String: Bool] = [:]
    var disabledCommands: [String] = []
    /// When each command that carries an alias or a hotkey was first found missing.
    var missingSince: [String: Date] = [:]
    /// Confirmations the user asked not to see again, as `<feature id>.<key>`.
    var suppressedConfirmations: [String] = []
    /// The option the user last picked in a remembered filter dropdown, by page.
    var filterSelections: [String: String] = [:]
    /// The user's fallback switches and order. Nil until the user changed a fallback, and in a file
    /// an older version wrote.
    var fallbackChoices: FallbackChoices?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aliases, hotkeys, favorites, features, disabledCommands, missingSince, suppressedConfirmations
        case filterSelections, fallbackChoices
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliases = (try? container.decodeIfPresent([String: String].self, forKey: .aliases)) ?? [:]
        let combos = (try? container.decodeIfPresent([String: String].self, forKey: .hotkeys)) ?? [:]
        hotkeys = combos.compactMapValues(KeyCombo.init(parsing:))
        favorites = (try? container.decodeIfPresent([String].self, forKey: .favorites)) ?? []
        features = (try? container.decodeIfPresent([String: Bool].self, forKey: .features)) ?? [:]
        disabledCommands = (try? container.decodeIfPresent([String].self, forKey: .disabledCommands)) ?? []
        missingSince = (try? container.decodeIfPresent([String: Date].self, forKey: .missingSince)) ?? [:]
        suppressedConfirmations =
            (try? container.decodeIfPresent([String].self, forKey: .suppressedConfirmations)) ?? []
        filterSelections = (try? container.decodeIfPresent([String: String].self, forKey: .filterSelections)) ?? [:]
        fallbackChoices = try? container.decodeIfPresent(FallbackChoices.self, forKey: .fallbackChoices)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(hotkeys.mapValues(\.description), forKey: .hotkeys)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(features, forKey: .features)
        try container.encode(disabledCommands, forKey: .disabledCommands)
        try container.encode(missingSince, forKey: .missingSince)
        try container.encode(suppressedConfirmations, forKey: .suppressedConfirmations)
        try container.encode(filterSelections, forKey: .filterSelections)
        try container.encodeIfPresent(fallbackChoices, forKey: .fallbackChoices)
    }
}
