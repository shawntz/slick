import Foundation
import Kit

/// Whether the chosen provider can answer now.
nonisolated enum Readiness: Sendable {
    case ready(any ModelProvider)
    case needsSetup(SetupReason)
}

/// Why the setup form shows.
nonisolated enum SetupReason: Hashable, Sendable {
    /// The on-device model is chosen but cannot answer.
    case onDevice(OnDeviceStatus)
    /// Anthropic is chosen and there is no key.
    case missingAnthropicKey
    /// A server is chosen and its address or model name is missing or wrong.
    case incompleteServer
}

/// Makes the provider the settings choose, reading the key from the Keychain only when asked.
/// Nothing here sends a request; that starts when an answer streams.
nonisolated struct ProviderResolver: Sendable {
    let settings: FeatureSettings
    let secrets: FeatureSecrets
    let http: any HTTPService
    let onDevice: any OnDeviceModelService

    func resolve() async -> Readiness {
        switch settings[AISettings.provider] {
        case .onDevice:
            let status = await onDevice.status()
            guard status == .available else { return .needsSetup(.onDevice(status)) }
            return .ready(OnDeviceProvider(model: onDevice))
        case .anthropic:
            guard let key = await secret(AISecrets.anthropicKey) else { return .needsSetup(.missingAnthropicKey) }
            return .ready(AnthropicProvider(http: http, apiKey: key, model: settings[AISettings.anthropicModel]))
        case .openAICompatible:
            let model = settings[AISettings.serverModel].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = OpenAICompatibleProvider.parseAddress(settings[AISettings.serverAddress]),
                !model.isEmpty
            else {
                return .needsSetup(.incompleteServer)
            }
            return .ready(
                OpenAICompatibleProvider(
                    http: http, baseAddress: address, apiKey: await secret(AISecrets.serverKey), model: model))
        }
    }

    /// Where requests go with the current settings, without reading a secret: nil for the on-device
    /// model, or the host. For the settings pane.
    var destinationHost: String? {
        switch settings[AISettings.provider] {
        case .onDevice: nil
        case .anthropic: AnthropicProvider.host
        case .openAICompatible:
            OpenAICompatibleProvider.parseAddress(settings[AISettings.serverAddress]).map(
                OpenAICompatibleProvider.hostName(of:))
        }
    }

    /// True when requests would cross the network without encryption: a server address with plain
    /// `http` on another machine. For the settings pane.
    var destinationIsUnencrypted: Bool {
        guard settings[AISettings.provider] == .openAICompatible,
            let address = OpenAICompatibleProvider.parseAddress(settings[AISettings.serverAddress])
        else {
            return false
        }
        return OpenAICompatibleProvider.isUnencrypted(address)
    }

    /// A stored secret without surrounding white space, or nil when there is none.
    func secret(_ name: String) async -> String? {
        guard let value = try? await secrets.value(for: name) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
