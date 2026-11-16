import Foundation
import Kit
import KitHosting
import Observation

/// One item of a feature's declarative settings pane, with the state its control needs.
///
/// Values are read from the feature's settings on every read and written at once, so the feature
/// sees changes through ``FeatureSettings/changes(of:)``. Secrets go through
/// ``FeatureSecrets``, never settings.
@Observable final class PaneItemModel: Identifiable {
    /// The item as the feature last declared it.
    @ObservationIgnored var item: SettingsItem
    @ObservationIgnored private unowned let page: FeatureDetailModel
    @ObservationIgnored private var recorder: HotkeyRecorderModel?

    /// Multi-select options, loaded when the page appears.
    private(set) var choices: [SettingsChoice] = []
    private(set) var isLoadingChoices = false
    /// The secret as typed, stored on ``saveSecret()``.
    var secretDraft = ""
    /// True when the Keychain holds a value for the secret.
    private(set) var hasSecret = false
    /// New text for a text list.
    var listDraft = ""
    /// True while a button's work runs.
    private(set) var isRunning = false

    init(item: SettingsItem, page: FeatureDetailModel) {
        self.item = item
        self.page = page
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var title: String { item.title }
    var info: String? { item.info }
    var control: SettingsControl { item.control }

    /// True when a new declaration can keep this model's state.
    func sameKind(as other: SettingsItem) -> Bool {
        switch (item.control, other.control) {
        case (.toggle(let a), .toggle(let b)), (.picker(let a, _), .picker(let b, _)),
            (.textField(let a, _), .textField(let b, _)), (.stepper(let a, _, _, _), .stepper(let b, _, _, _)),
            (.hotkey(let a), .hotkey(let b)), (.list(let a, _, _), .list(let b, _, _)),
            (.multiSelect(let a, _), .multiSelect(let b, _)), (.application(let a), .application(let b)):
            return a == b
        case (.secret(let a, _), .secret(let b, _)):
            return a == b
        case (.permission(let a), .permission(let b)):
            return a == b
        case (.button, .button), (.note, .note):
            return item.title == other.title
        default:
            return false
        }
    }

    private var context: SettingsContext { page.context }
    private var entry: FeatureEntry? { page.entry }

    // MARK: Values

    /// The stored value, or the key's default.
    var storage: SettingStorage {
        get {
            page.settingsRevision.track()
            guard let key = control.key, let entry else { return .empty }
            return entry.context.settings.storage(of: key)
        }
        set {
            guard let key = control.key, let entry else { return }
            entry.context.settings.write(newValue, for: key)
            page.settingsRevision.bump()
        }
    }

    var bool: Bool {
        get { Bool(settingStorage: storage) ?? false }
        set { storage = newValue.settingStorage }
    }

    var int: Int {
        get { Int(settingStorage: storage) ?? 0 }
        set {
            guard case .stepper(_, let range, _, _) = control else { return }
            storage = min(max(newValue, range.lowerBound), range.upperBound).settingStorage
        }
    }

    var text: String {
        get { String(settingStorage: storage) ?? "" }
        set { storage = newValue.settingStorage }
    }

    var strings: [String] {
        get { [String](settingStorage: storage) ?? [] }
        set { storage = newValue.settingStorage }
    }

    // MARK: Picker

    var options: [SettingsOption] {
        if case .picker(_, let options) = control { return options }
        return []
    }

    /// The index of the chosen option, or nil when the stored value matches none. Setting it
    /// chooses that option through ``choose(_:)``.
    var pickerIndex: Int? {
        get {
            let value = storage
            return options.firstIndex { $0.value == value }
        }
        set {
            guard let newValue, options.indices.contains(newValue) else { return }
            choose(options[newValue].value)
        }
    }

    /// The question open for a picker choice, while the user has not answered it.
    private(set) var pendingChoice: Confirmation?

    /// Stores a picker choice. A choice the feature asks about first, such as a shorter history that
    /// deletes items at once, is stored only when the user goes ahead. Until the answer, and after
    /// a no, the picker shows the stored choice.
    func choose(_ value: SettingStorage) {
        guard let key = control.key, let entry else { return }
        let stored = context.services.settings.storage(for: entry.context.settings.storageName(for: key.name))
        guard let confirmation = item.confirmation(choosing: value, stored: stored) else {
            storage = value
            return
        }
        pendingChoice = confirmation
        page.settingsRevision.bump()
        let confirmations = context.confirmations
        Task { [weak self] in
            let goAhead = await confirmations.ask(confirmation)
            guard let self else { return }
            self.pendingChoice = nil
            if goAhead {
                self.storage = value
            } else {
                self.page.settingsRevision.bump()
            }
        }
    }

    // MARK: Hotkey

    /// The recorder for a hotkey item.
    var hotkey: HotkeyRecorderModel? {
        guard case .hotkey(let key) = control, let entry else { return nil }
        if let recorder { return recorder }
        let made = context.recorder(
            HotkeyTargets.setting(key, title: title, settings: entry.context.settings, preferences: context.preferences)
        )
        recorder = made
        return made
    }

    // MARK: Secret

    /// Reads whether a secret is stored, without showing it.
    func loadSecret() async {
        guard case .secret(let name, _) = control, let entry else { return }
        do {
            hasSecret = try await entry.context.secrets.value(for: name).map { !$0.isEmpty } ?? false
        } catch {
            hasSecret = false
            context.toasts.show(error, title: "Could not read \(title)")
        }
    }

    /// Stores the typed secret in the Keychain and clears the field. Empty text does nothing.
    func saveSecret() async {
        guard case .secret(let name, _) = control, let entry else { return }
        let value = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try await entry.context.secrets.set(value, for: name)
            secretDraft = ""
            hasSecret = true
            context.toasts.show(.success("Saved \(title)"))
        } catch {
            context.toasts.show(error, title: "Could not save \(title)")
        }
    }

    /// Deletes the stored secret.
    func removeSecret() async {
        guard case .secret(let name, _) = control, let entry else { return }
        do {
            try await entry.context.secrets.set(nil, for: name)
            secretDraft = ""
            hasSecret = false
        } catch {
            context.toasts.show(error, title: "Could not remove \(title)")
        }
    }

    // MARK: Button

    /// Runs a button as an action launched from settings: confirmation first, toasts in the window,
    /// and a failure toast for a thrown error.
    func run() async {
        guard case .button(_, let confirmation, let run) = control, let entry, !isRunning else { return }
        if let confirmation, !(await context.confirmations.ask(confirmation)) { return }
        isRunning = true
        defer { isRunning = false }
        let actionContext = ActionContext(feature: entry.context, host: page.host, launch: .settings)
        do {
            try await run(actionContext)
        } catch {
            context.toasts.show(error, title: "\(title) failed")
        }
        page.settingsRevision.bump()
    }

    var buttonStyle: Action.Style {
        if case .button(let style, _, _) = control { return style }
        return .regular
    }

    // MARK: List

    var listKind: EditableListKind {
        if case .list(_, let kind, _) = control { return kind }
        return .text
    }

    /// Adds the typed text to a text list. Empty or repeated text is ignored.
    func addDraft() {
        let value = listDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        listDraft = ""
        if !strings.contains(value) { strings.append(value) }
    }

    /// Asks for apps or folders, by the list's kind, and adds them.
    func addFromPicker() async {
        let picked: [String]
        switch listKind {
        case .text: return
        case .application: picked = await chooseApplications(multiple: true)
        case .folder:
            let request = OpenDialogRequest(title: title, allowsMultiple: true, canChooseDirectories: true)
            picked = await context.services.fileDialogs.chooseFiles(request).map(\.path)
        }
        var values = strings
        for value in picked where !values.contains(value) { values.append(value) }
        strings = values
    }

    func removeEntries(at offsets: IndexSet) {
        var values = strings
        for index in offsets.sorted(by: >) where values.indices.contains(index) { values.remove(at: index) }
        strings = values
    }

    func remove(_ value: String) {
        strings = strings.filter { $0 != value }
    }

    /// How a list entry reads: an app's name for an app list, a folder's path with the home folder
    /// shortened, the text otherwise.
    func label(forEntry value: String) -> String {
        switch listKind {
        case .text: value
        case .application: applicationName(value) ?? value
        case .folder: displayPath(value)
        }
    }

    // MARK: Multi-select

    /// Calls the feature for its options, as each time the pane shows.
    func loadChoices() async {
        guard case .multiSelect(_, let options) = control else { return }
        isLoadingChoices = true
        choices = await options()
        isLoadingChoices = false
    }

    func isChosen(_ id: String) -> Bool {
        strings.contains(id)
    }

    func setChosen(_ chosen: Bool, _ id: String) {
        var values = strings.filter { $0 != id }
        if chosen { values.append(id) }
        strings = values
    }

    // MARK: Application

    /// The chosen app's name, or nil when none is chosen.
    var applicationTitle: String? {
        let bundleID = text
        guard !bundleID.isEmpty else { return nil }
        return applicationName(bundleID) ?? bundleID
    }

    func chooseApplication() async {
        guard let bundleID = await chooseApplications(multiple: false).first else { return }
        text = bundleID
    }

    func clearApplication() {
        guard let key = control.key, let entry else { return }
        entry.context.settings.write(nil, for: key)
        page.settingsRevision.bump()
    }

    private func chooseApplications(multiple: Bool) async -> [String] {
        let request = OpenDialogRequest(title: title, allowedTypes: ["app"], allowsMultiple: multiple)
        let urls = await context.services.fileDialogs.chooseFiles(request)
        return urls.compactMap { context.dependencies.bundleIdentifier($0) }
    }

    private func applicationName(_ bundleID: String) -> String? {
        context.services.workspace.application(bundleID: bundleID)?.name
    }

    private func displayPath(_ path: String) -> String {
        let home = context.services.storage.homeDirectory.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: Permission

    var permission: Permission? {
        if case .permission(let permission) = control { return permission }
        return nil
    }

    var permissionStatus: PermissionStatus {
        page.settingsRevision.track()
        guard let permission else { return .notDetermined }
        return context.permissions.status(of: permission)
    }

    /// The reason the feature's manifest gives for the permission.
    var permissionReason: String? {
        guard let permission else { return nil }
        return entry?.manifest.permissions.first { $0.permission == permission }?.reason
    }

    func grant() async {
        guard let permission else { return }
        _ = await context.permissions.grant(permission)
        page.settingsRevision.bump()
    }

    /// Opens the permission's pane in System Settings. When the page shows again with the permission
    /// granted there, the features hear of it.
    func openPermissionSettings() async {
        guard let permission else { return }
        context.grants.watch(permission)
        await context.permissions.openSettings(for: permission)
    }

    // MARK: Appearing

    /// Loads what the control needs when the page shows.
    func appeared() async {
        switch control {
        case .multiSelect: await loadChoices()
        case .secret: await loadSecret()
        case .permission:
            page.settingsRevision.bump()
            if let permission { await context.grants.check(permission) }
        default: break
        }
    }
}
