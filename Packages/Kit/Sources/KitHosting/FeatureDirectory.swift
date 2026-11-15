import Kit

/// The registered features, what each declares, and whether each feature and command is on.
///
/// Host's feature runtime implements it. Root reads it to build its catalog, providers and
/// suggestions, and SettingsUI reads it to draw the features list and each feature's pane. Neither
/// imports Host.
///
/// The directory holds a feature's declarations as the runtime last read them: at registration and
/// after each ``Feature/declarationChanges``. Declarations of a feature that is off stay listed, so
/// settings can show its commands. Root search uses only what is on.
@MainActor public protocol FeatureDirectory: AnyObject, Sendable {
    /// Every registered feature in registration order, on or off.
    var features: [FeatureEntry] { get }

    /// Sent after anything in ``features`` changed: a feature's declarations, or a feature or command
    /// turned on or off. Read ``features`` again when it fires.
    var changes: ChangeSignal { get }

    /// Tells the features that the user granted a permission through one of Slick's own Grant
    /// buttons. Each feature that is on and lists the permission in its manifest hears
    /// ``Kit/Feature/permissionGranted(_:)``, in registration order. Returns once each has returned.
    ///
    /// SettingsUI calls it after a Grant button in settings or onboarding ends with the permission
    /// granted, and after it sees a permission it asked for turn granted while it watches. Host's
    /// runtime implements it, and calls it itself after a grant through the panel's permission
    /// card. The default does nothing, for a directory that cannot reach its features.
    func permissionGranted(_ permission: Permission) async
}

extension FeatureDirectory {
    public func permissionGranted(_ permission: Permission) async {}
}

extension FeatureDirectory {
    /// The feature with this manifest ID, on or off.
    public func feature(_ id: String) -> FeatureEntry? {
        features.first { $0.id == id }
    }

    /// The command with this `cmd:` ID, on or off. Nil when no registered feature declares it.
    public func command(_ id: ItemID) -> CommandEntry? {
        guard id.namespace == ItemID.ReservedNamespace.command else { return nil }
        for entry in features {
            if let command = entry.commands.first(where: { $0.id == id }) { return command }
        }
        return nil
    }

    /// The features that are on, in registration order.
    public var enabledFeatures: [FeatureEntry] {
        features.filter(\.isEnabled)
    }

    /// The feature that owns an ``ItemID`` namespace and the object that makes actions for its rows:
    /// a catalog source, a live provider or a suggestion trigger. Root uses it to route a remembered
    /// row back to its source. Nil when no feature that is on claims the namespace.
    public func provider(forNamespace namespace: String) -> (feature: FeatureEntry, actions: any RowActionProvider)? {
        for entry in features where entry.isEnabled {
            if let source = entry.catalogSources.first(where: { $0.namespace == namespace }) {
                return (entry, source)
            }
            if let provider = entry.liveProviders.first(where: { $0.namespace == namespace }) {
                return (entry, provider.actionProvider)
            }
            if let trigger = entry.suggestionTriggers.first(where: { $0.namespace == namespace }) {
                return (entry, trigger)
            }
        }
        return nil
    }
}

/// One registered feature: its manifest, whether it is on, its context and its declarations.
public struct FeatureEntry: Identifiable, Sendable {
    /// Who the feature is.
    public var manifest: FeatureManifest
    /// True while the feature is on. The user's switch, or the manifest's default until the user
    /// sets one.
    public var isEnabled: Bool
    /// The context the feature was made with. A host builds an ``ActionContext`` for one of the
    /// feature's rows from it, and reads the feature's settings and storage through it.
    public var context: FeatureContext
    /// Every command the feature declares, in its order, each with its own switch.
    public var commands: [CommandEntry]
    public var catalogSources: [any CatalogSource]
    public var liveProviders: [LiveProvider]
    public var suggestionTriggers: [any SuggestionTrigger]
    public var universalActions: [UniversalActionProvider]
    public var settingsPane: SettingsPane?
    public var hotkeyPresets: [HotkeyPreset]
    /// What the feature's background work wants the user to know. Nil when all is well.
    public var status: FeatureStatus?
    public var provides: [ProvidedService]

    /// The manifest ID.
    public var id: String { manifest.id }

    public init(
        manifest: FeatureManifest,
        isEnabled: Bool,
        context: FeatureContext,
        commands: [CommandEntry] = [],
        catalogSources: [any CatalogSource] = [],
        liveProviders: [LiveProvider] = [],
        suggestionTriggers: [any SuggestionTrigger] = [],
        universalActions: [UniversalActionProvider] = [],
        settingsPane: SettingsPane? = nil,
        hotkeyPresets: [HotkeyPreset] = [],
        status: FeatureStatus? = nil,
        provides: [ProvidedService] = []
    ) {
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.context = context
        self.commands = commands
        self.catalogSources = catalogSources
        self.liveProviders = liveProviders
        self.suggestionTriggers = suggestionTriggers
        self.universalActions = universalActions
        self.settingsPane = settingsPane
        self.hotkeyPresets = hotkeyPresets
        self.status = status
        self.provides = provides
    }

    /// Reads every declaration of a feature, as a runtime does at registration and after
    /// ``Feature/declarationChanges``.
    ///
    /// - Parameters:
    ///   - feature: The feature, made with `context`.
    ///   - context: The context the feature was made with.
    ///   - isEnabled: Whether the feature is on.
    ///   - isCommandEnabled: The user's switch for one command, by its `cmd:` ID. A command is on
    ///     only when this is true and the feature is on.
    @MainActor public init(
        reading feature: any Feature,
        context: FeatureContext,
        isEnabled: Bool,
        isCommandEnabled: (ItemID) -> Bool = { _ in true }
    ) {
        let manifest = type(of: feature).manifest
        self.init(
            manifest: manifest,
            isEnabled: isEnabled,
            context: context,
            commands: feature.commands.map { command in
                let id = command.itemID(feature: manifest.id)
                return CommandEntry(
                    id: id, featureID: manifest.id, command: command, isEnabled: isEnabled && isCommandEnabled(id))
            },
            catalogSources: feature.catalogSources,
            liveProviders: feature.liveProviders,
            suggestionTriggers: feature.suggestionTriggers,
            universalActions: feature.universalActions,
            settingsPane: feature.settingsPane,
            hotkeyPresets: feature.hotkeyPresets,
            status: feature.status,
            provides: feature.provides)
    }
}

/// One command of a registered feature.
public struct CommandEntry: Identifiable, Sendable {
    /// The command's root ID, `cmd:<feature id>.<command id>`.
    public var id: ItemID
    /// The manifest ID of the feature that declares it.
    public var featureID: String
    /// The command as the feature declared it.
    public var command: Command
    /// False when the user turned the command off or its feature is off. A command that is off does
    /// not show in root search, and its hotkey and fallback do nothing.
    public var isEnabled: Bool

    public init(id: ItemID, featureID: String, command: Command, isEnabled: Bool) {
        self.id = id
        self.featureID = featureID
        self.command = command
        self.isEnabled = isEnabled
    }
}
