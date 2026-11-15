import Kit
import KitHosting
import KitTesting

/// A feature directory in memory, for Root and SettingsUI tests that need features without Host.
///
/// Set ``entries`` directly, or ``register(_:fakes:isEnabled:)`` real features over
/// ``FakeServices``. Every change sends ``changes``, as the runtime does.
@MainActor public final class FakeFeatureDirectory: FeatureDirectory {
    public let changes = ChangeSignal()

    /// Every feature in registration order. Setting it sends ``changes``.
    public var entries: [FeatureEntry] {
        didSet { changes.send() }
    }

    private var instances: [String: any Feature] = [:]
    private var disabledCommands: Set<ItemID> = []

    public init(_ entries: [FeatureEntry] = []) {
        self.entries = entries
    }

    public var features: [FeatureEntry] { entries }

    /// Makes a feature over the fakes, reads its declarations and appends its entry. The directory
    /// keeps the feature alive. It does not call ``Feature/activate()``; a test that needs the
    /// feature's background work calls it on the returned feature.
    ///
    /// - Parameter isEnabled: Whether the feature is on. Nil takes the manifest's default.
    @discardableResult
    public func register<F: Feature>(_ type: F.Type, fakes: FakeServices, isEnabled: Bool? = nil) -> F {
        let (entry, feature) = FeatureEntry.make(type, fakes: fakes, isEnabled: isEnabled)
        instances[entry.id] = feature
        entries.append(entry)
        return feature
    }

    /// The feature object behind a registered entry.
    public func instance(_ featureID: String) -> (any Feature)? {
        instances[featureID]
    }

    /// Reads a registered feature's declarations again, as the runtime does after
    /// ``Feature/declarationChanges``.
    public func reload(_ featureID: String) {
        guard let index = entries.firstIndex(where: { $0.id == featureID }), let feature = instances[featureID]
        else { return }
        let old = entries[index]
        entries[index] = FeatureEntry(
            reading: feature, context: old.context, isEnabled: old.isEnabled,
            isCommandEnabled: { [disabledCommands] in !disabledCommands.contains($0) })
    }

    /// Turns a feature on or off in the directory, and its commands with it. Calls neither
    /// ``Feature/activate()`` nor ``Feature/deactivate()``.
    public func setEnabled(_ enabled: Bool, feature featureID: String) {
        guard let index = entries.firstIndex(where: { $0.id == featureID }) else { return }
        var entry = entries[index]
        entry.isEnabled = enabled
        for commandIndex in entry.commands.indices {
            let id = entry.commands[commandIndex].id
            entry.commands[commandIndex].isEnabled = enabled && !disabledCommands.contains(id)
        }
        entries[index] = entry
    }

    /// Turns one command on or off. It is on only while its feature is on too.
    public func setEnabled(_ enabled: Bool, command id: ItemID) {
        if enabled { disabledCommands.remove(id) } else { disabledCommands.insert(id) }
        for index in entries.indices {
            guard let commandIndex = entries[index].commands.firstIndex(where: { $0.id == id }) else { continue }
            entries[index].commands[commandIndex].isEnabled = enabled && entries[index].isEnabled
        }
    }
}

extension FeatureEntry {
    /// Makes a feature over ``FakeServices`` and reads its declarations into an entry, as the runtime
    /// does at registration. Keep the returned feature alive for as long as the entry is used:
    /// commands and actions may hold it weakly.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the feature is on. Nil takes the manifest's default.
    ///   - environment: The run environment of the feature's context.
    @MainActor public static func make<F: Feature>(
        _ type: F.Type, fakes: FakeServices, isEnabled: Bool? = nil, environment: RunEnvironment = .selftest
    ) -> (entry: FeatureEntry, feature: F) {
        let context = fakes.context(featureID: F.manifest.id, environment: environment)
        let feature = F(context: context)
        let entry = FeatureEntry(
            reading: feature, context: context, isEnabled: isEnabled ?? F.manifest.isEnabledByDefault)
        return (entry, feature)
    }
}
