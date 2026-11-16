import Foundation
import Kit
import KitHosting
import os

/// The feature runtime: it makes every feature, reads and re-reads what each declares, turns
/// features and commands on and off, binds item hotkeys, and runs commands and actions through one
/// pipeline.
///
/// It is the app's ``FeatureDirectory``. Its ``preferences`` are the app's ``ItemPreferences``, and
/// its ``pipeline`` runs everything a user starts.
///
/// ```swift
/// let runtime = FeatureRuntime(services: services, environment: .live, dataDirectory: folder)
/// await runtime.start([FeatureRegistration(ClipboardFeature.self), ...])
/// ```
@MainActor public final class FeatureRuntime: FeatureDirectory {
    public let changes = ChangeSignal()
    /// Every registered feature in registration order, on or off.
    public private(set) var features: [FeatureEntry] = []
    public let services: Services
    public let environment: RunEnvironment
    /// What the user attached to items, kept in the data directory.
    public let preferences: HostPreferences
    /// Runs commands and actions.
    public private(set) lazy var pipeline = RunPipeline(runtime: self)
    /// Root search, for hotkeys bound to items that are not commands. App sets it.
    public weak var rootSource: (any RootSource)?
    /// Problems found by ``FeatureValidator`` at registration and after each re-read, by feature
    /// ID. A feature with problems still runs; `--selftest` fails on them.
    public private(set) var issues: [String: [FeatureIssue]] = [:]
    /// A context for work the host does itself, such as running a row that Root made. Its feature
    /// ID is the general settings namespace, which no feature can take.
    public let hostContext: FeatureContext

    var instances: [String: any Feature] = [:]
    private var commandIndex: [ItemID: CommandEntry] = [:]
    private var declarationWatchers: [String: Task<Void, Never>] = [:]
    private var active: Set<String> = []
    private let log = KitLog.logger(category: "host.runtime")

    /// - Parameters:
    ///   - services: The services every feature context is built over.
    ///   - environment: The run environment of every feature context.
    ///   - dataDirectory: The host's own folder. Preferences live in `preferences.json` inside it.
    public init(services: Services, environment: RunEnvironment, dataDirectory: URL) {
        self.services = services
        self.environment = environment
        hostContext = FeatureContext(featureID: HostSettings.namespace, environment: environment, services: services)
        preferences = HostPreferences(
            file: dataDirectory.appending(path: "preferences.json", directoryHint: .notDirectory),
            hotkeys: services.hotkeys, settings: services.settings, clock: services.clock)
        preferences.runtime = self
    }

    /// Loads preferences, registers the features and activates those that are on.
    public func start(_ registrations: [FeatureRegistration]) async {
        await preferences.load()
        register(registrations)
        await activateEnabledFeatures()
    }

    // MARK: Registration

    /// Makes each feature, validates it and reads its declarations. A feature whose ID is invalid
    /// or already taken is skipped, because the ID prefixes everything it owns.
    public func register(_ registrations: [FeatureRegistration]) {
        for registration in registrations {
            let id = registration.manifest.id
            guard FeatureValidator.isValidFeatureID(id), instances[id] == nil else {
                issues[id, default: []].append("feature \"\(id)\" was skipped: its ID is invalid or already registered")
                continue
            }
            let context = FeatureContext(featureID: id, environment: environment, services: services)
            let feature = registration.make(context)
            instances[id] = feature
            let found = FeatureValidator.validate(feature)
            if !found.isEmpty {
                issues[id] = found
                log.error("feature \(id, privacy: .public) has \(found.count) problems")
            }
            let isEnabled = preferences.isEnabled(feature: id, default: registration.manifest.isEnabledByDefault)
            features.append(read(feature, context: context, isEnabled: isEnabled))
            if let signal = feature.declarationChanges { watchDeclarations(of: id, signal) }
        }
        didChangeDeclarations()
    }

    /// Activates every feature that is on and not active yet, concurrently, then binds hotkeys.
    public func activateEnabledFeatures() async {
        let ids = features.filter(\.isEnabled).map(\.id).filter { !active.contains($0) }
        active.formUnion(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.activateFeature(id) }
            }
        }
        preferences.rebindHotkeys()
    }

    /// Deactivates every active feature and cancels its running handlers, as at quit.
    public func deactivateAll() async {
        let ids = Array(active)
        active.removeAll()
        for id in ids { pipeline.cancelHandlers(of: id) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.deactivateFeature(id) }
            }
        }
        for watcher in declarationWatchers.values { watcher.cancel() }
        declarationWatchers.removeAll()
        preferences.unbindAllHotkeys()
        await preferences.flush()
    }

    private func activateFeature(_ id: String) async {
        await instances[id]?.activate()
    }

    private func deactivateFeature(_ id: String) async {
        await instances[id]?.deactivate()
    }

    private func waitUntilReady(_ id: String) async {
        await instances[id]?.waitUntilReady()
    }

    // MARK: Lookup

    /// The command with this `cmd:` ID, on or off. A dictionary lookup, cheap enough for a keystroke.
    public func command(_ id: ItemID) -> CommandEntry? {
        commandIndex[id]
    }

    /// True when the command exists and is on, with its feature.
    public func isAvailable(_ id: ItemID) -> Bool {
        commandIndex[id]?.isEnabled ?? false
    }

    /// The actions the panel shows: those whose ``Action/requiresCommand`` is unavailable are hidden.
    public func visible(_ actions: [Action]) -> [Action] {
        guard actions.contains(where: { $0.requiresCommand != nil }) else { return actions }
        return actions.filter { action in action.requiresCommand.map(isAvailable) ?? true }
    }

    /// The context of a registered feature, or the host's own context.
    public func context(for featureID: String?) -> FeatureContext {
        featureID.flatMap { feature($0)?.context } ?? hostContext
    }

    /// The feature object behind a registered ID. For tests and the self-test.
    public func instance(_ featureID: String) -> (any Feature)? {
        instances[featureID]
    }

    /// True while the feature is activated.
    public func isActive(_ featureID: String) -> Bool {
        active.contains(featureID)
    }

    /// Returns once every active feature says the work its activation started is done, through
    /// `Feature.waitUntilReady()`, all at once. Scenarios, the self-test and benchmarks call it before
    /// they type. The live launcher never does.
    public func waitUntilFeaturesAreReady() async {
        let ids = features.map(\.id).filter { active.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.waitUntilReady(id) }
            }
        }
    }

    // MARK: Grants

    /// Tells every feature that is on and lists the permission in its manifest that the user
    /// granted it through one of the app's own buttons: the settings window, onboarding or the
    /// panel's permission card. In registration order; returns once each has returned.
    public func permissionGranted(_ permission: Permission) async {
        for entry in features where entry.isEnabled && active.contains(entry.id) {
            guard entry.manifest.permissions.contains(where: { $0.permission == permission }),
                let feature = instances[entry.id]
            else { continue }
            await feature.permissionGranted(permission)
        }
    }

    // MARK: Changes

    /// Reads a feature's declarations again, as after its ``Feature/declarationChanges``.
    public func reread(_ featureID: String) {
        guard let index = features.firstIndex(where: { $0.id == featureID }), let feature = instances[featureID]
        else { return }
        let old = features[index]
        let found = FeatureValidator.validate(feature)
        issues[featureID] = found.isEmpty ? nil : found
        features[index] = read(feature, context: old.context, isEnabled: old.isEnabled)
        didChangeDeclarations()
    }

    /// Turns a feature on or off: activates or deactivates it, cancels its handlers when it goes
    /// off, rebinds hotkeys and sends ``changes``.
    func setFeatureEnabled(_ enabled: Bool, featureID: String) async {
        guard let index = features.firstIndex(where: { $0.id == featureID }), let feature = instances[featureID]
        else { return }
        let old = features[index]
        features[index] = read(feature, context: old.context, isEnabled: enabled)
        rebuildIndex()
        changes.send()
        if enabled, !active.contains(featureID) {
            active.insert(featureID)
            await feature.activate()
        } else if !enabled, active.contains(featureID) {
            active.remove(featureID)
            pipeline.cancelHandlers(of: featureID)
            await feature.deactivate()
        }
        preferences.rebindHotkeys()
    }

    /// Applies a command switch to the entries and rebinds hotkeys.
    func commandSwitchChanged() {
        for index in features.indices {
            let featureOn = features[index].isEnabled
            for commandIndex in features[index].commands.indices {
                let id = features[index].commands[commandIndex].id
                features[index].commands[commandIndex].isEnabled = featureOn && preferences.isEnabled(command: id)
            }
        }
        rebuildIndex()
        changes.send()
        preferences.rebindHotkeys()
    }

    private func read(_ feature: any Feature, context: FeatureContext, isEnabled: Bool) -> FeatureEntry {
        let preferences = preferences
        return FeatureEntry(
            reading: feature, context: context, isEnabled: isEnabled,
            isCommandEnabled: { preferences.isEnabled(command: $0) })
    }

    private func didChangeDeclarations() {
        rebuildIndex()
        preferences.reconcileCommands(declared: Set(commandIndex.keys))
        changes.send()
        preferences.rebindHotkeys()
    }

    private func rebuildIndex() {
        var index: [ItemID: CommandEntry] = [:]
        for entry in features {
            for command in entry.commands where index[command.id] == nil { index[command.id] = command }
        }
        commandIndex = index
    }

    private func watchDeclarations(of featureID: String, _ signal: ChangeSignal) {
        let stream = signal.stream()
        declarationWatchers[featureID] = Task { [weak self] in
            for await _ in stream {
                self?.reread(featureID)
            }
        }
    }

    // MARK: Hotkeys

    /// True when an item's hotkey should be bound now: a command that exists and is on, or any
    /// other item.
    func canBindHotkey(for id: ItemID) -> Bool {
        id.namespace == ItemID.ReservedNamespace.command ? isAvailable(id) : true
    }

    /// Runs what an item's hotkey stands for. A command runs with launch `.hotkey`. Any other item
    /// is looked up in root search and its first action runs.
    func hotkeyPressed(_ id: ItemID) {
        if id.namespace == ItemID.ReservedNamespace.command {
            pipeline.runCommand(id, launch: .hotkey)
            return
        }
        guard let root = rootSource, let row = root.row(for: id), let action = root.actions(for: row).first else {
            pipeline.presenter?.showHUD(.failure(HostStrings.itemUnavailable))
            return
        }
        let featureID = root.featureID(for: row)
        root.didRun(row, launch: .hotkey)
        pipeline.perform(
            action, featureID: featureID ?? HostSettings.namespace, context: context(for: featureID), query: "",
            launch: .hotkey, row: row)
    }
}
