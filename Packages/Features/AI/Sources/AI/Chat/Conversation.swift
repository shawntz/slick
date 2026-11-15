import Foundation
import Kit

/// Why an answer ended before the model finished on its own.
nonisolated enum AnswerEnding: Codable, Hashable, Sendable {
    /// The user stopped it, sent a follow-up while it ran, or left the page.
    case stopped
    /// It reached the response length limit.
    case lengthLimit
    /// The model declined.
    case refused
    /// Something went wrong; the failure says what to do.
    case failed(AIFailure)
}

/// One message of a conversation.
nonisolated struct ChatMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
    }

    var role: Role
    /// What was sent, or what the model answered.
    var text: String
    /// What the transcript shows for a question whose text is a command's whole prompt, such as
    /// "Improve Writing".
    var label: String?
    var date: Date
    /// The model that answered, for an answer.
    var model: String?
    /// Anthropic thinking blocks to send back with this answer.
    var replay: [AnthropicReplayBlock]?
    /// Set when the answer ended early.
    var ending: AnswerEnding?

    init(
        role: Role, text: String, label: String? = nil, date: Date, model: String? = nil,
        replay: [AnthropicReplayBlock]? = nil, ending: AnswerEnding? = nil
    ) {
        self.role = role
        self.text = text
        self.label = label
        self.date = date
        self.model = model
        self.replay = replay
        self.ending = ending
    }

    /// The message as a provider sends it.
    var turn: ModelTurn {
        ModelTurn(role == .user ? .user : .assistant, text, replay: replay ?? [])
    }
}

/// A conversation: what AI Chat keeps, one JSON file each.
///
/// The system prompt is kept with the conversation, so changing it in settings affects new
/// conversations only, and an Anthropic answer's thinking stays valid to send back.
nonisolated struct Conversation: Codable, Hashable, Sendable, Identifiable {
    static let currentVersion = 1

    var version: Int
    var id: String
    var title: String
    var hasCustomTitle: Bool
    var created: Date
    var updated: Date
    var systemPrompt: String
    var messages: [ChatMessage]

    init(
        id: String = UUID().uuidString.lowercased(), title: String = "", hasCustomTitle: Bool = false, created: Date,
        systemPrompt: String, messages: [ChatMessage] = []
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.created = created
        self.updated = created
        self.systemPrompt = systemPrompt
        self.messages = messages
    }

    /// The title to show: the one the user gave, else one made from the first question.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user }) else { return Strings.Chat.untitled }
        return Transcript.title(from: first.label ?? first.text)
    }

    /// The last answer's text, for the list's subtitle.
    var lastAnswer: String? {
        messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    /// True when the conversation holds anything worth keeping.
    var hasMessages: Bool { !messages.isEmpty }

    /// True for a file written by a newer version of the feature, which this one must not overwrite.
    var isFromNewerVersion: Bool { version > Self.currentVersion }
}
