import Kit
import KitHosting

/// What root search reads from the feature directory, prepared once per directory change so a
/// keystroke only walks short arrays.
///
/// Only features that are on count, and only their commands that are on. Built-in sources come
/// first. A namespace belongs to the first source that claims it, in the order
/// ``FeatureDirectory/provider(forNamespace:)`` uses: features in registration order, and inside one
/// feature its catalog sources, then live providers, then suggestion triggers.
struct DirectoryPlan {
    /// Who makes a namespace's rows, and so their actions.
    struct Owner {
        /// Nil for a built-in source.
        var featureID: String?
        var actions: any RowActionProvider
    }

    struct InstantEntry {
        var provider: any InstantProvider
        var namespace: String
        var featureID: String
        /// The ID of the provider's own section when its answer does not claim the top.
        var sectionID: String
    }

    struct AsyncEntry {
        var provider: any AsyncProvider
        var namespace: String
        var featureID: String
        var sectionID: String
    }

    /// A command that can appear in the fallback list.
    struct FallbackEntry {
        var id: ItemID
        var title: @Sendable (String) -> String
        var subtitle: String?
        var icon: Icon?
    }

    /// A catalog source to load, with the settings its reload keys live in.
    struct SourceEntry {
        var source: any CatalogSource
        /// Nil for a built-in source.
        var featureID: String?
        var settings: FeatureSettings?
    }

    /// A suggestion trigger of a feature that is on.
    struct TriggerEntry {
        var trigger: any SuggestionTrigger
        var featureID: String
        /// `<feature id>.<trigger id>`, the key its learning is kept under.
        var typeKey: String
        var settings: FeatureSettings
        var permissions: PermissionReader
    }

    var commands: [CatalogInputs.CommandInput] = []
    var instantProviders: [InstantEntry] = []
    var asyncProviders: [AsyncEntry] = []
    var triggers: [TriggerEntry] = []
    /// The live subtitles of commands that are on and show in root search, by `cmd:` ID.
    var liveSubtitles: [ItemID: LiveSubtitle] = [:]
    /// Commands that are on and may run with the typed text on Tab.
    var tabCommands: Set<ItemID> = []
    var owners: [String: Owner] = [:]
    /// The feature of each owned namespace, for the catalog builder off the main thread.
    var ownerFeatures: [String: CatalogInputs.Owner] = [:]
    /// The feature of each command that is on, by `cmd:` ID.
    var commandFeatures: [ItemID: String] = [:]
    /// Every command that is on and declares a fallback.
    var fallbacks: [ItemID: FallbackEntry] = [:]
    /// Those commands in registration order, for the user's fallback choices to arrange.
    var fallbackCommands: [CommandEntry] = []
    var sources: [SourceEntry] = []

    init() {}

    init(features: [FeatureEntry], builtInSources: [any CatalogSource]) {
        for source in builtInSources {
            sources.append(SourceEntry(source: source, featureID: nil, settings: nil))
            claim(source.namespace, featureID: nil, actions: source)
        }
        for feature in features where feature.isEnabled {
            readCommands(of: feature)
            for source in feature.catalogSources {
                sources.append(SourceEntry(source: source, featureID: feature.id, settings: feature.context.settings))
                claim(source.namespace, featureID: feature.id, actions: source)
            }
            for live in feature.liveProviders {
                let namespace = live.namespace
                switch live {
                case .instant(let provider):
                    instantProviders.append(
                        InstantEntry(
                            provider: provider, namespace: namespace, featureID: feature.id,
                            sectionID: "provider." + namespace))
                case .async(let provider):
                    asyncProviders.append(
                        AsyncEntry(
                            provider: provider, namespace: namespace, featureID: feature.id,
                            sectionID: "async." + namespace))
                }
                claim(namespace, featureID: feature.id, actions: live.actionProvider)
            }
            for trigger in feature.suggestionTriggers {
                claim(trigger.namespace, featureID: feature.id, actions: trigger)
                triggers.append(
                    TriggerEntry(
                        trigger: trigger, featureID: feature.id, typeKey: feature.id + "." + trigger.id,
                        settings: feature.context.settings, permissions: feature.context.permissions))
            }
        }
    }

    private mutating func readCommands(of feature: FeatureEntry) {
        for entry in feature.commands where entry.isEnabled {
            commandFeatures[entry.id] = feature.id
            if entry.command.takesRootQueryOnTab { tabCommands.insert(entry.id) }
            if entry.command.showsInRoot {
                commands.append(
                    CatalogInputs.CommandInput(
                        entry: entry, featureName: feature.manifest.name, featureIcon: feature.manifest.icon))
                if let live = entry.command.liveSubtitle { liveSubtitles[entry.id] = live }
            }
            if let fallback = entry.command.fallback {
                fallbacks[entry.id] = FallbackEntry(
                    id: entry.id, title: fallback.title, subtitle: feature.manifest.name,
                    icon: entry.command.icon ?? feature.manifest.icon)
                fallbackCommands.append(entry)
            }
        }
    }

    private mutating func claim(_ namespace: String, featureID: String?, actions: any RowActionProvider) {
        if owners[namespace] == nil {
            owners[namespace] = Owner(featureID: featureID, actions: actions)
            ownerFeatures[namespace] = CatalogInputs.Owner(featureID: featureID)
        }
    }

    /// The fallback list root search shows: the fallbacks that are on, in the user's order, as
    /// ``FallbackChoices/list(_:)`` arranges them. A fallback the user never switched follows its
    /// ``Fallback/startsOn``. While the user has set no choice, a list in the older
    /// ``HostSettings/fallbackCommands`` setting still decides, in its order, so a settings pane
    /// that writes it keeps working. Commands that are off or declare no fallback are left out.
    func fallbackList(choices: FallbackChoices, legacy: [String]) -> [FallbackEntry] {
        if choices.isEmpty, !legacy.isEmpty {
            return legacy.compactMap(ItemID.init(rawValue:)).compactMap { fallbacks[$0] }
        }
        return choices.list(fallbackCommands).compactMap { $0.isOn ? fallbacks[$0.id] : nil }
    }
}

/// The general settings root search reads, cached so a keystroke never reads the settings store.
struct RootSettingsCache: Equatable {
    var showSuggestions: Bool
    var suggestionCount: Int
    var showFavorites: Bool
    var inlineCompletion: Bool
    var fallbackCommands: [String]
    var learningPaused: Bool
    var tabCommand: String
    /// ``tabCommand`` parsed once, so a keystroke never parses it.
    var tabCommandID: ItemID?
    /// How many rows the list shows before it scrolls: the rows whose live subtitles refresh.
    var visibleRows: Int

    init(_ settings: FeatureSettings) {
        visibleRows = max(1, settings[HostSettings.visibleRows])
        showSuggestions = settings[HostSettings.showSuggestions]
        suggestionCount = max(0, settings[HostSettings.suggestionCount])
        showFavorites = settings[HostSettings.showFavorites]
        inlineCompletion = settings[HostSettings.inlineCompletion]
        fallbackCommands = settings[HostSettings.fallbackCommands]
        learningPaused = settings[HostSettings.learningPaused]
        tabCommand = settings[HostSettings.tabCommand]
        tabCommandID = tabCommand.isEmpty ? nil : ItemID(rawValue: tabCommand)
    }

    /// The keys above, whose changes root search follows.
    static var keys: [AnySettingKey] {
        [
            HostSettings.showSuggestions.erased, HostSettings.suggestionCount.erased,
            HostSettings.showFavorites.erased, HostSettings.inlineCompletion.erased,
            HostSettings.fallbackCommands.erased, HostSettings.learningPaused.erased,
            HostSettings.tabCommand.erased, HostSettings.visibleRows.erased,
        ]
    }
}

/// One catalog source and the rows it last loaded.
final class SourceSlot {
    let source: any CatalogSource
    let featureID: String?
    /// The rows of the last load that succeeded. A load that throws keeps them.
    var rows: [Row] = []
    var isLoading = false
    /// A change arrived during a load, so the source loads once more when it ends.
    var reloadRequested = false
    var listeners: [Task<Void, Never>] = []

    init(source: any CatalogSource, featureID: String?) {
        self.source = source
        self.featureID = featureID
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners = []
    }
}

/// An async provider section the current query waits for, in display order.
struct PendingProvider {
    var provider: any AsyncProvider
    var namespace: String
    var sectionID: String
    /// True when the provider claimed the query, so root search shows only its rows.
    var takesOver: Bool
    /// The section heading for this query, read in the keystroke.
    var title: String
    /// The most rows the section shows. Unlimited for a provider that took the query over.
    var maximumRows: Int
    /// True once the provider delivered, failed or was dropped.
    var isDone = false
}

/// One suggestion trigger and the suggestions it gave last.
final class TriggerSlot {
    let trigger: any SuggestionTrigger
    let featureID: String
    let typeKey: String
    let permissions: PermissionReader
    /// The suggestions of the last ask that succeeded. An ask that throws keeps them.
    var suggestions: [Suggestion] = []
    var isAsking = false
    /// A reason to ask arrived during an ask, so the trigger is asked once more when it ends.
    var askAgain = false
    var listeners: [Task<Void, Never>] = []

    init(_ entry: DirectoryPlan.TriggerEntry) {
        trigger = entry.trigger
        featureID = entry.featureID
        typeKey = entry.typeKey
        permissions = entry.permissions
    }

    /// True when every permission the trigger needs is granted. Never prompts.
    var isPermitted: Bool {
        trigger.requires.allSatisfy { permissions.isGranted($0) }
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners = []
    }
}
