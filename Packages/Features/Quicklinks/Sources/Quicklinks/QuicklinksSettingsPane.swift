import Kit

/// The feature's pane in the settings window. Read again with the other declarations after every
/// change, so the engine picker lists the searches that are on now.
enum QuicklinksSettingsPane {
    static func make(feature: QuicklinksFeature) -> SettingsPane {
        let engines = feature.searchEngines.map { (value: $0.id, title: $0.quicklink.name) }
        let restore = Confirmation(
            Strings.restoreTitle, message: Strings.restoreMessage, confirmTitle: Strings.restoreConfirm,
            isDestructive: true)
        return SettingsPane([
            SettingsSection(
                Strings.webSearchSection,
                items: [
                    .picker(
                        Strings.defaultEngineSetting, key: QuicklinksSettings.defaultSearch, options: engines,
                        info: Strings.defaultEngineInfo),
                    .toggle(
                        Strings.fallbacksSetting, key: QuicklinksSettings.offersFallbacks, info: Strings.fallbacksInfo),
                    .toggle(
                        Strings.addressesSetting, key: QuicklinksSettings.detectsAddresses, info: Strings.addressesInfo),
                ]),
            SettingsSection(
                Strings.quicklinksSection,
                items: [
                    .button(Strings.restoreButton, confirmation: restore, info: Strings.restoreInfo) {
                        [unowned feature] context in
                        try await feature.restoreDefaults()
                        context.showToast(.success(Strings.restoredDefaults))
                    },
                    .button(Strings.revealButton, info: Strings.revealInfo) { [unowned feature] context in
                        await context.workspace.reveal([feature.fileURL])
                    },
                ]),
        ])
    }
}
