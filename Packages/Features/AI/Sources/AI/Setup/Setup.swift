import Foundation
import Kit

extension AIFeature {
    /// Shows the setup form any time, to choose or change the provider.
    var setupCommand: Command {
        Command(
            id: "setup", title: Strings.Setup.commandTitle, icon: .symbol("gearshape"), keywords: Strings.Setup.keywords
        ) { [weak self] _ in
            guard let self else { return .keepOpen }
            return .push(.form(await self.setupForm(reason: nil) { .close(hud: .success(Strings.Setup.saved)) }))
        }
    }

    /// A short form that chooses a provider and fills in what it needs, then runs `next`. The
    /// on-device model is offered first when the Mac has it, because it needs no key and sends
    /// nothing. Keys go to the Keychain; the rest goes to settings.
    func setupForm(reason: SetupReason?, then next: @escaping @MainActor () -> ActionOutcome) async -> FormPage {
        let onDevice = onDevice
        let resolver = resolver
        let current = settings[AISettings.provider]
        let onDeviceStatus = await onDevice.status()
        let hasAnthropicKey = await resolver.secret(AISecrets.anthropicKey) != nil
        let hasServerKey = await resolver.secret(AISecrets.serverKey) != nil
        let suggested: ProviderKind = current == .onDevice && onDeviceStatus != .available ? .anthropic : current
        let providers = ProviderKind.allCases.map {
            CommandArgument.Option(Strings.Setup.providerTitle($0), value: $0.rawValue)
        }
        let models = AnthropicModel.allCases.map {
            CommandArgument.Option(Strings.Settings.modelTitle($0), value: $0.rawValue)
        }
        return FormPage(
            title: Strings.Setup.title,
            fields: [
                .description(Strings.Setup.intro(reason: reason)),
                .dropdown("provider", title: Strings.Setup.provider, options: providers, initial: suggested.rawValue),
                .description(Strings.Setup.onDeviceNote(onDeviceStatus)),
                .separator("anthropic-separator"),
                .password(
                    "anthropicKey", title: Strings.Setup.anthropicKey,
                    placeholder: hasAnthropicKey ? Strings.Setup.keepsSavedKey : Strings.Setup.anthropicKeyPlaceholder),
                .dropdown(
                    "anthropicModel", title: Strings.Setup.anthropicModel, options: models,
                    initial: settings[AISettings.anthropicModel].rawValue),
                .separator("server-separator"),
                .text(
                    "serverAddress", title: Strings.Setup.serverAddress,
                    placeholder: Strings.Settings.serverAddressPlaceholder, initial: settings[AISettings.serverAddress]),
                .text(
                    "serverModel", title: Strings.Setup.serverModel,
                    placeholder: Strings.Settings.serverModelPlaceholder,
                    initial: settings[AISettings.serverModel]),
                .password(
                    "serverKey", title: Strings.Setup.serverKey,
                    placeholder: hasServerKey ? Strings.Setup.keepsSavedKey : Strings.Setup.optional),
                .description(Strings.Setup.privacy),
            ],
            submitTitle: Strings.Setup.submit,
            validate: { values in
                await Self.validateSetup(values, onDevice: onDevice, hasAnthropicKey: hasAnthropicKey)
            },
            submit: { [weak self] values, context in
                guard let self else { return .pop }
                try await self.applySetup(values, context: context)
                return next()
            })
    }

    /// Checks only what the chosen provider needs.
    nonisolated static func validateSetup(
        _ values: FormValues, onDevice: any OnDeviceModelService, hasAnthropicKey: Bool
    ) async -> [String: FieldError] {
        switch ProviderKind(rawValue: values.text("provider")) ?? .onDevice {
        case .onDevice:
            let status = await onDevice.status()
            return status == .available ? [:] : ["provider": FieldError(Strings.Setup.onDeviceNote(status))]
        case .anthropic:
            let key = values.text("anthropicKey").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty && !hasAnthropicKey {
                return ["anthropicKey": FieldError(Strings.Setup.anthropicKeyMissing)]
            }
            if key.contains(where: { $0.isWhitespace }) {
                return ["anthropicKey": FieldError(Strings.Setup.keyHasSpaces)]
            }
            return [:]
        case .openAICompatible:
            var errors: [String: FieldError] = [:]
            if OpenAICompatibleProvider.parseAddress(values.text("serverAddress")) == nil {
                errors["serverAddress"] = FieldError(Strings.Setup.serverAddressInvalid)
            }
            if values.text("serverModel").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors["serverModel"] = FieldError(Strings.Setup.serverModelMissing)
            }
            return errors
        }
    }

    /// Saves the choice: settings for the provider, and keys the user typed to the Keychain. A key
    /// field left empty keeps the saved key.
    private func applySetup(_ values: FormValues, context: ActionContext) async throws {
        let provider = ProviderKind(rawValue: values.text("provider")) ?? .onDevice
        switch provider {
        case .onDevice:
            break
        case .anthropic:
            if let model = AnthropicModel(rawValue: values.text("anthropicModel")) {
                settings[AISettings.anthropicModel] = model
            }
            let key = values.text("anthropicKey").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try await context.secrets.set(key, for: AISecrets.anthropicKey) }
        case .openAICompatible:
            settings[AISettings.serverAddress] = values.text("serverAddress").trimmingCharacters(
                in: .whitespacesAndNewlines)
            settings[AISettings.serverModel] = values.text("serverModel").trimmingCharacters(
                in: .whitespacesAndNewlines)
            let key = values.text("serverKey").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try await context.secrets.set(key, for: AISecrets.serverKey) }
        }
        settings[AISettings.provider] = provider
    }
}
