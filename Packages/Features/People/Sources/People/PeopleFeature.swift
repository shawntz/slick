import Foundation
import Kit

/// Contacts: find a person and reach them.
///
/// - Search Contacts lists everyone with a detail pane: phone numbers, email addresses, postal
///   addresses, birthday, company and a thumbnail of the photo (`PeopleList.swift`).
/// - Each person's actions call, message, email, FaceTime, copy or open them, depending on what the
///   card holds (`PeopleActions.swift`). Every URL comes from a pure builder (`ContactLinks.swift`).
/// - People join root search by name once the user allowed access, behind a setting that is on by
///   default (`PeopleCatalog.swift`).
/// - Everything comes from the contact store behind ``PeopleService``: `CNContactStore` in the app,
///   an in-memory store everywhere else. The directory reads it off the main thread, keeps it in
///   memory and follows its changes (`PeopleDirectory.swift`).
///
/// Nothing is read at activation. Access is asked for only when the user runs Search Contacts, or
/// presses Allow Access to Contacts in settings or on the list. A grant made through the launcher
/// arrives as ``permissionGranted(_:)``; the feature holds no permission stream.
public final class PeopleFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "contacts", name: Strings.featureName, icon: .symbol("person.crop.circle"), summary: Strings.summary,
        permissions: [PermissionNeed(.contacts, reason: Strings.permissionReason)])

    let context: FeatureContext
    let service: any PeopleService
    let directory: PeopleDirectory
    private let builder: PeopleActions
    let list: PeopleList
    private let catalog: PeopleCatalog
    private var isActive = false

    /// Does no I/O. The service touches nothing until something reads people.
    public init(context: FeatureContext) {
        self.context = context
        service = context.service(PeopleServiceKey.self)
        directory = PeopleDirectory(service: service, permissions: context.permissions, log: context.log)
        builder = PeopleActions(directory: directory, settings: context.settings)
        list = PeopleList(directory: directory, actions: builder, locale: context.clock.locale)
        catalog = PeopleCatalog(directory: directory, actions: builder, settings: context.settings)
    }

    /// Reads nothing and asks for nothing. Root search reads people when it asks the catalog, and
    /// only once the user allowed access.
    public func activate() async {
        isActive = true
    }

    /// Forgets everyone the feature held in memory.
    public func deactivate() async {
        isActive = false
        directory.forget()
    }

    /// The user allowed Contacts through the launcher: in settings, in onboarding or on the
    /// panel's permission card. The list and root search read people again.
    public func permissionGranted(_ permission: Permission) async {
        guard isActive, permission == .contacts else { return }
        accessGranted()
    }

    public var catalogSources: [any CatalogSource] { [catalog] }

    public var commands: [Command] {
        [
            Command(
                id: "search", title: Strings.Commands.search, icon: Self.manifest.icon,
                keywords: Strings.Commands.searchKeywords, requires: [.contacts],
                fallback: Fallback { Strings.Commands.fallback($0) }, takesRootQueryOnTab: true
            ) { [list] context in
                let typed = [.fallback, .tabFromRoot].contains(context.launch) ? context.query : ""
                return .push(.list(list.page(initialQuery: typed)))
            }
        ]
    }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.Settings.searchSection,
                items: [
                    .toggle(
                        Strings.Settings.showsInRootSearch, key: PeopleSettings.showsInRootSearch,
                        info: Strings.Settings.showsInRootSearchInfo)
                ]),
            SettingsSection(
                Strings.Settings.actionsSection,
                items: [
                    .picker(
                        Strings.Settings.primaryAction, key: PeopleSettings.primaryAction,
                        info: Strings.Settings.primaryActionInfo, titles: Strings.Settings.primaryActionTitle),
                    .application(
                        Strings.Settings.callApp, key: PeopleSettings.callApp, info: Strings.Settings.callAppInfo),
                ]),
            SettingsSection(
                Strings.Settings.accessSection, footer: Strings.Settings.privacyNote,
                items: [
                    .button(Strings.Settings.allowAccess, info: Strings.Settings.allowAccessInfo) {
                        [weak self] context in
                        await self?.allowAccess(context)
                    }
                ]),
        ])
    }

    // MARK: - Access

    /// The settings button: asks through the host, which shows the system prompt the first time and
    /// opens System Settings after a refusal. Then reads people. A grant made later in System
    /// Settings is read the next time Search Contacts opens.
    func allowAccess(_ context: ActionContext) async {
        let status = await context.requestPermission(.contacts)
        switch status {
        case .granted:
            accessGranted()
            context.showToast(.success(Strings.Access.onTitle))
        case .restricted:
            context.showToast(.failure(Strings.Access.offTitle, message: Strings.Access.restrictedMessage))
        case .denied, .notDetermined:
            context.showToast(Toast(.info, Strings.Access.offTitle, message: Strings.Access.turnOnMessage))
        }
    }

    /// Access arrived: whatever showed nothing for lack of it reloads, and reads the store.
    private func accessGranted() {
        directory.changes.send()
    }
}
