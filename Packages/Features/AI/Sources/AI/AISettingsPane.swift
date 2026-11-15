import Foundation
import Kit

extension AIFeature {
    /// The pane: the provider and what it needs, how answers are made, how long chats are kept, and
    /// what is sent where. It is read again whenever the provider settings change, so the footer
    /// always names the host the next request goes to.
    public var settingsPane: SettingsPane? {
        let provider = settings[AISettings.provider]
        return SettingsPane([
            SettingsSection(
                Strings.Settings.providerSection,
                footer: Strings.Settings.whatIsSent(
                    provider: provider, host: resolver.destinationHost,
                    isUnencrypted: resolver.destinationIsUnencrypted),
                items: [
                    .picker(
                        Strings.Settings.provider, key: AISettings.provider, info: Strings.Settings.providerInfo,
                        titles: Strings.Setup.providerTitle)
                ]),
            SettingsSection(
                Strings.Settings.anthropicSection, footer: Strings.Settings.anthropicFooter,
                items: [
                    .secret(
                        Strings.Settings.apiKey, name: AISecrets.anthropicKey,
                        placeholder: Strings.Setup.anthropicKeyPlaceholder, info: Strings.Settings.anthropicKeyInfo),
                    .picker(
                        Strings.Settings.model, key: AISettings.anthropicModel,
                        info: Strings.Settings.anthropicModelInfo,
                        titles: Strings.Settings.modelTitle),
                ]),
            SettingsSection(
                Strings.Settings.serverSection, footer: Strings.Settings.serverFooter,
                items: [
                    .textField(
                        Strings.Settings.serverAddress, key: AISettings.serverAddress,
                        placeholder: Strings.Settings.serverAddressPlaceholder, info: Strings.Settings.serverAddressInfo
                    ),
                    .textField(
                        Strings.Settings.serverModel, key: AISettings.serverModel,
                        placeholder: Strings.Settings.serverModelPlaceholder, info: Strings.Settings.serverModelInfo),
                    .secret(
                        Strings.Settings.apiKey, name: AISecrets.serverKey, placeholder: Strings.Setup.optional,
                        info: Strings.Settings.serverKeyInfo),
                ]),
            SettingsSection(
                Strings.Settings.answersSection,
                items: [
                    .textField(
                        Strings.Settings.systemPrompt, key: AISettings.systemPrompt,
                        info: Strings.Settings.systemPromptInfo),
                    .picker(
                        Strings.Settings.responseLength, key: AISettings.responseLength,
                        info: Strings.Settings.responseLengthInfo, titles: Strings.Settings.lengthTitle),
                    .textField(
                        Strings.Settings.translateLanguage, key: AISettings.translateLanguage,
                        placeholder: Strings.Settings.defaultLanguage, info: Strings.Settings.translateLanguageInfo),
                ]),
            SettingsSection(
                Strings.Settings.chatsSection, footer: Strings.Settings.storageFooter(dataFolder),
                items: [
                    .picker(
                        Strings.Settings.keepChats, key: AISettings.retention, info: Strings.Settings.keepChatsInfo,
                        titles: Strings.Settings.retentionTitle, confirm: Self.retentionConfirmation),
                    .button(
                        Strings.Chat.deleteAll, style: .destructive,
                        confirmation: Confirmation(
                            Strings.Chat.deleteAllQuestion, message: Strings.Chat.cannotUndo,
                            confirmTitle: Strings.Chat.deleteAllConfirm, isDestructive: true),
                        info: Strings.Settings.deleteAllInfo
                    ) { [store] context in
                        let count = try await store.deleteAll()
                        context.showToast(.success(Strings.Chat.deletedAll(count)))
                    },
                ]),
            SettingsSection(
                Strings.Settings.permissionsSection,
                items: [.permission(.accessibility, info: Strings.Settings.accessibilityInfo)]),
        ])
    }

    /// The question a shorter time to keep chats asks first, because it deletes chats at once. Nil
    /// for a choice that deletes nothing.
    static func retentionConfirmation(from stored: ChatRetention, to chosen: ChatRetention) -> Confirmation? {
        guard chosen.deletesMore(than: stored) else { return nil }
        return Confirmation(
            chosen.keepsChats ? Strings.Settings.deleteOlderQuestion : Strings.Chat.deleteAllQuestion,
            message: Strings.Settings.retentionMessage(chosen), confirmTitle: Strings.Settings.deleteConfirm,
            isDestructive: true)
    }

    /// The data folder as people read it, with the home folder as "~".
    var dataFolder: String {
        let path = context.storage.dataDirectory.path(percentEncoded: false)
        let home = context.storage.homeDirectory.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty, path.hasPrefix(trimmedHome + "/") else { return path }
        return "~" + path.dropFirst(trimmedHome.count)
    }
}
