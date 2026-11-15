import Foundation
import Kit
import KitHosting
import Observation

/// One feature's page: its switch, its status with Grant buttons, its commands with alias, hotkey
/// and switch, its hotkey presets, and its own settings pane.
@Observable final class FeatureDetailModel {
    let featureID: String
    @ObservationIgnored let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private var commandModels: [ItemID: CommandRowModel] = [:]
    @ObservationIgnored private var itemModels: [String: PaneItemModel] = [:]
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var observedKeys: [String] = []
    private let revision = Revision()
    /// Shared by the pane's items, bumped when one of the feature's settings changes.
    @ObservationIgnored let settingsRevision = Revision()
    /// The preset waiting for the user to confirm, with what it would change.
    var presetReview: PresetReview?
    /// The ActionHost the pane's buttons run with.
    @ObservationIgnored private(set) lazy var host = SettingsActionHost(
        toasts: context.toasts, confirmations: context.confirmations, permissions: context.permissions,
        onReload: { [weak self] in self?.reloadSettings() })

    init(featureID: String, context: SettingsContext) {
        self.featureID = featureID
        self.context = context
        tasks.follow(context.directory.changes, bumping: revision)
        tasks.follow(context.preferences.changes, bumping: revision)
    }

    isolated deinit {
        settingsTask?.cancel()
    }

    /// The feature's entry as the directory holds it now.
    var entry: FeatureEntry? {
        revision.track()
        return context.directory.feature(featureID)
    }

    var name: String { entry?.manifest.name ?? featureID }

    /// The feature's switch.
    var isEnabled: Bool {
        revision.track()
        return context.preferences.isEnabled(feature: featureID)
    }

    func setEnabled(_ enabled: Bool) async {
        await context.preferences.setEnabled(enabled, feature: featureID)
        revision.bump()
    }

    // MARK: Status

    /// What the feature wants the user to know, if anything.
    var status: FeatureStatus? { entry?.status }

    /// The permissions the status asks for that are not granted yet, each with the feature's reason.
    var missingStatusPermissions: [PermissionNeed] {
        guard let entry, let status = entry.status else { return [] }
        revision.track()
        return status.requires.filter { !context.permissions.status(of: $0).isGranted }.map { permission in
            entry.manifest.permissions.first { $0.permission == permission }
                ?? PermissionNeed(permission, reason: status.title)
        }
    }

    func grant(_ permission: Permission) async {
        _ = await context.permissions.grant(permission)
        revision.bump()
        settingsRevision.bump()
    }

    // MARK: Commands

    /// The feature's commands, each with its alias, hotkey and switch.
    var commands: [CommandRowModel] {
        guard let entry else { return [] }
        return entry.commands.map { command in
            if let model = commandModels[command.id] { return model }
            let model = CommandRowModel(entry: command, context: context)
            commandModels[command.id] = model
            return model
        }
    }

    // MARK: Presets

    var presets: [HotkeyPreset] { entry?.hotkeyPresets ?? [] }

    /// Shows what a preset would change before anything is bound.
    func review(_ preset: HotkeyPreset) {
        guard let entry else { return }
        presetReview = PresetReview(preset: preset, entry: entry, context: context)
    }

    /// Binds every command of the reviewed preset that can take its hotkey, and reports the rest.
    func applyReviewedPreset() {
        guard let review = presetReview else { return }
        presetReview = nil
        let failures = review.apply()
        for model in commandModels.values { model.hotkey.refresh() }
        if failures.isEmpty {
            context.toasts.show(.success("Applied \(review.preset.name)"))
        } else {
            context.toasts.show(
                .failure(
                    "Applied \(review.preset.name) in part",
                    message: "Not bound: " + failures.joined(separator: ", ") + "."))
        }
        revision.bump()
    }

    func cancelPresetReview() {
        presetReview = nil
    }

    // MARK: Settings pane

    /// The sections of the feature's own settings pane, each with its item models.
    var sections: [PaneSectionModel] {
        guard let entry, let pane = entry.settingsPane else { return [] }
        observeSettings(of: pane)
        return pane.sections.enumerated().map { sectionIndex, section in
            PaneSectionModel(
                id: sectionIndex, title: section.title, footer: section.footer,
                items: section.items.enumerated().map { itemIndex, item in
                    let key = "\(sectionIndex).\(itemIndex).\(item.title)"
                    if let model = itemModels[key], model.sameKind(as: item) {
                        model.item = item
                        return model
                    }
                    let model = PaneItemModel(item: item, page: self)
                    itemModels[key] = model
                    return model
                })
        }
    }

    /// Loads what the pane shows that needs a call: multi-select options, whether secrets are set,
    /// and permission status. The view calls it each time the page appears.
    func appeared() async {
        let items = sections.flatMap(\.items)
        for item in items { await item.appeared() }
        revision.bump()
    }

    /// Reads every setting again, after a button asked for a reload or after a grant.
    func reloadSettings() {
        settingsRevision.bump()
        revision.bump()
    }

    private func observeSettings(of pane: SettingsPane) {
        let keys = pane.sections.flatMap(\.items).compactMap(\.control.key)
        let names = keys.map(\.name)
        guard names != observedKeys, let entry else { return }
        observedKeys = names
        settingsTask?.cancel()
        let stream = entry.context.settings.changes(ofAny: keys)
        settingsTask = Task { [weak settingsRevision] in
            for await _ in stream { settingsRevision?.bump() }
        }
    }
}

/// One section of a feature's settings pane.
struct PaneSectionModel: Identifiable {
    var id: Int
    var title: String?
    var footer: String?
    var items: [PaneItemModel]
}

/// One command on a feature's page: its alias, hotkey and switch.
@Observable final class CommandRowModel: Identifiable {
    let id: ItemID
    let title: String
    let subtitle: String?
    let icon: Icon?
    let hotkey: HotkeyRecorderModel
    @ObservationIgnored private let context: SettingsContext
    private let revision = Revision()
    /// The alias as typed, stored on ``commitAlias()``.
    var aliasDraft: String

    init(entry: CommandEntry, context: SettingsContext) {
        id = entry.id
        title = entry.command.title
        subtitle = entry.command.subtitle
        icon = entry.command.icon
        self.context = context
        hotkey = context.recorder(
            HotkeyTargets.item(entry.id, title: entry.command.title, preferences: context.preferences))
        aliasDraft = context.preferences.aliases[entry.id] ?? ""
    }

    /// The stored alias.
    var alias: String {
        revision.track()
        return context.preferences.aliases[id] ?? ""
    }

    /// Stores the alias as typed, trimmed and lowercased. Empty removes it.
    func commitAlias() {
        let cleaned = aliasDraft.trimmingCharacters(in: .whitespaces).lowercased()
        aliasDraft = cleaned
        guard cleaned != alias else { return }
        context.preferences.setAlias(cleaned.isEmpty ? nil : cleaned, for: id)
        revision.bump()
    }

    /// The user's switch for the command.
    var isEnabled: Bool {
        get {
            revision.track()
            return context.preferences.isEnabled(command: id)
        }
        set {
            context.preferences.setEnabled(newValue, command: id)
            revision.bump()
        }
    }
}
