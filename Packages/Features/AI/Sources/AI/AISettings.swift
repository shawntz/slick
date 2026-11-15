import Foundation
import Kit

/// Where AI questions go.
nonisolated enum ProviderKind: String, SettingValue, CaseIterable, Codable, Sendable {
    /// Apple's model on this Mac. Needs no key and sends nothing.
    case onDevice
    /// The Anthropic Messages API, with the user's key.
    case anthropic
    /// Any server that speaks the OpenAI chat completions format, such as Ollama or LM Studio.
    case openAICompatible
}

/// The Anthropic models the settings offer. The raw values are the API's model IDs.
nonisolated enum AnthropicModel: String, SettingValue, CaseIterable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case fable = "claude-fable-5-2"

    /// True when the API takes server-side fallbacks for this model. Claude Haiku 5.5 refuses them.
    var takesFallbacks: Bool { self != .haiku }
}

/// How long an answer may get.
nonisolated enum ResponseLength: String, SettingValue, CaseIterable, Sendable {
    case short
    case standard
    case long

    /// The token limit sent to the Anthropic API. Current models think before they answer, and the
    /// thinking counts toward the limit, so even Short leaves room for it.
    var anthropicMaximumTokens: Int {
        switch self {
        case .short: 4_096
        case .standard: 16_000
        case .long: 64_000
        }
    }

    /// The token limit sent to an OpenAI-compatible server. Smaller, because some servers refuse a
    /// limit above what their model can write.
    var serverMaximumTokens: Int {
        switch self {
        case .short: 1_024
        case .standard: 4_096
        case .long: 16_000
        }
    }

    /// The limit for the on-device model, whose context is small. Nil leaves the model's own limit.
    var onDeviceMaximumTokens: Int? {
        self == .short ? 512 : nil
    }
}

/// How long AI Chat keeps conversations.
nonisolated enum ChatRetention: String, SettingValue, CaseIterable, Sendable {
    case none
    case day
    case week
    case month
    case year
    case forever

    /// How old a conversation may get before it is deleted. Nil keeps it; zero keeps nothing.
    var maximumAge: TimeInterval? {
        switch self {
        case .none: 0
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        case .forever: nil
        }
    }

    /// True when chats are written to disk at all.
    var keepsChats: Bool { self != .none }

    /// True when choosing `self` over `stored` deletes chats at once: a shorter time, or none.
    func deletesMore(than stored: ChatRetention) -> Bool {
        (maximumAge ?? .infinity) < (stored.maximumAge ?? .infinity)
    }
}

/// The feature's settings. Stored as `ai.<name>`.
nonisolated enum AISettings {
    static let provider = SettingKey("provider", default: ProviderKind.onDevice)
    static let anthropicModel = SettingKey("anthropicModel", default: AnthropicModel.opus)
    static let serverAddress = SettingKey("serverAddress", default: "")
    static let serverModel = SettingKey("serverModel", default: "")
    static let systemPrompt = SettingKey("systemPrompt", default: Prompts.defaultSystem)
    static let responseLength = SettingKey("responseLength", default: ResponseLength.standard)
    static let translateLanguage = SettingKey("translateLanguage", default: Strings.Settings.defaultLanguage)
    static let retention = SettingKey("chatRetention", default: ChatRetention.forever)

    /// The settings that change where requests go, which the settings pane describes.
    static var destinationKeys: [AnySettingKey] {
        [provider.erased, anthropicModel.erased, serverAddress.erased, serverModel.erased]
    }
}

/// Names of the feature's secrets in the Keychain, stored as `ai.<name>`.
nonisolated enum AISecrets {
    static let anthropicKey = "anthropicKey"
    static let serverKey = "serverKey"
}
