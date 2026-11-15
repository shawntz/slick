import Foundation
import Kit
import Synchronization

/// What an answer page is for, which decides its actions.
nonisolated enum AnswerMode: Hashable, Sendable {
    /// Ask AI: a question and its answer, with follow-ups. Nothing is kept unless the user moves it to
    /// AI Chat.
    case ask
    /// A command on text. The first question is the command's whole prompt, so it is not shown.
    case text(TextOutput)
    /// A conversation in AI Chat, saved after each answer.
    case chat

    var hidesFirstQuestion: Bool {
        if case .text = self { return true }
        return false
    }
}

/// How a command's result goes back.
nonisolated struct TextOutput: Hashable, Sendable {
    /// The paste action's title: "Replace Selection" for text selected in another app.
    var pasteTitle: String
    /// True makes pasting the first action, so Return runs it.
    var pastesFirst: Bool
}

/// What an answer page needs from the feature.
nonisolated struct AnswerServices: Sendable {
    let resolver: ProviderResolver
    let store: ConversationStore
    let settings: FeatureSettings
    let clock: any ClockService

    /// A new, empty conversation with the current system prompt.
    func newConversation() -> Conversation {
        Conversation(created: clock.now, systemPrompt: settings[AISettings.systemPrompt])
    }

    /// Deletes chats older than the settings keep them, or all of them when the settings keep none.
    /// Reads only the chats folder's listing.
    func pruneChats() async throws {
        let retention = settings[AISettings.retention]
        if !retention.keepsChats {
            try await store.deleteAll()
        } else if let age = retention.maximumAge {
            try await store.prune(before: clock.now.addingTimeInterval(-age))
        }
    }
}

/// An answer page: shows a conversation, streams the answer to its last question, and takes
/// follow-ups. Ask AI, the text commands and AI Chat all use it.
///
/// The provider is resolved for each answer, so a change in settings applies to the next one. The
/// request and its parsing run in a detached task; the page's state changes on the main actor when
/// an answer ends. The text so far is kept in an ``AnswerBuffer`` that the main actor can read at
/// once, so Stop, a follow-up or Regenerate can keep a partial answer without waiting for the task.
final class AnswerSession: DetailSource {
    let actionsChanged: ChangeSignal? = ChangeSignal()
    let followUp: FollowUp?
    let pageTitle: String
    let mode: AnswerMode
    private(set) var conversation: Conversation
    /// The last fenced code block of the last answer, found off the main thread when it ended.
    private(set) var lastCodeBlock: String?

    private let services: AnswerServices
    private var run: Run?
    private var runCount = 0
    private var saving: Task<Void, Never>?
    /// True while a question already in the conversation waits for the user to send it, as in a
    /// kept chat that was opened again. Regenerate or a follow-up sends it.
    private var holdsQuestion: Bool

    private struct Run {
        let id: Int
        let task: Task<Void, Never>
        let buffer: AnswerBuffer
    }

    /// - Parameter sendsOnOpen: False for a conversation opened from AI Chat, so an unanswered
    ///   question in it is not sent just because the chat was opened.
    init(
        conversation: Conversation, mode: AnswerMode, title: String, services: AnswerServices, sendsOnOpen: Bool = true
    ) {
        self.conversation = conversation
        self.mode = mode
        self.pageTitle = title
        self.services = services
        self.holdsQuestion = !sendsOnOpen
        let placeholder =
            switch mode {
            case .chat: Strings.Chat.messagePlaceholder
            case .ask where conversation.messages.isEmpty: Strings.Ask.firstQuestion
            case .ask, .text: Strings.Ask.followUp
            }
        self.followUp = FollowUp(placeholder: placeholder)
    }

    /// The page for this session.
    var page: Page {
        .detail(DetailPage(title: pageTitle, source: self))
    }

    var isStreaming: Bool { run != nil }

    /// True when the last question has no answer yet.
    var isAwaitingAnswer: Bool { conversation.messages.last?.role == .user }

    // MARK: - DetailSource

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        interrupt()
        if isAwaitingAnswer && !holdsQuestion { return answer() }
        let messages = conversation.messages
        let hides = mode.hidesFirstQuestion
        let hint: String? =
            switch mode {
            case .chat where messages.isEmpty: Strings.Chat.newChatHint
            case .ask where messages.isEmpty: Strings.Ask.emptyHint
            default: nil
            }
        let held = isAwaitingAnswer ? Transcript.heldNote : ""
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                let text = hint ?? (Transcript.render(messages, hidesFirstQuestion: hides) + held)
                continuation.yield(.replace(.markdown(text)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func followUp(_ text: String) -> AsyncThrowingStream<DetailUpdate, any Error> {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return AsyncThrowingStream { $0.finish() } }
        guard question.utf8.count <= TextInput.maximumBytes else {
            // Nothing is sent or kept. The note shows under what the page shows now.
            let note = Transcript.note(for: .failed(Strings.Failures.textTooLong)) ?? ""
            return AsyncThrowingStream { continuation in
                continuation.yield(.append(note))
                continuation.finish()
            }
        }
        interrupt()
        holdsQuestion = false
        conversation.messages.append(ChatMessage(role: .user, text: question, date: services.clock.now))
        conversation.updated = services.clock.now
        return answer()
    }

    func actions(for detail: Detail) -> [Action] {
        if isStreaming { return [stopAction] }
        guard let last = conversation.messages.last, last.role == .assistant else {
            return isAwaitingAnswer ? [regenerateAction] : []
        }
        var actions: [Action] = []
        if !last.text.isEmpty {
            actions += outputActions(for: last.text)
            if let code = lastCodeBlock {
                actions.append(
                    .copy(
                        code, title: Strings.Actions.copyCodeBlock, hud: Strings.Actions.copiedCodeBlock,
                        shortcut: KeyCombo(.c, [.option, .command])
                    ).with(id: "copy-code-block"))
            }
        }
        actions.append(regenerateAction)
        actions.append(mode == .chat ? newChatAction : continueInChatAction)
        return actions
    }

    // MARK: - Answering

    /// Streams the answer to the last question: the transcript first, then the provider's metadata
    /// and text, then a note when the answer ended early.
    private func answer() -> AsyncThrowingStream<DetailUpdate, any Error> {
        runCount += 1
        let id = runCount
        let buffer = AnswerBuffer()
        let messages = conversation.messages
        let request = ModelRequest(
            system: conversation.systemPrompt, turns: messages.map(\.turn),
            length: services.settings[AISettings.responseLength])
        let hides = mode.hidesFirstQuestion
        let resolver = services.resolver
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DetailUpdate.self)
        // The task holds the session until the answer ends, so an answer cut short by leaving the page
        // is still recorded and a chat still saved.
        let task = Task.detached {
            continuation.yield(.replace(.markdown(Transcript.render(messages, hidesFirstQuestion: hides))))
            let outcome = await Self.answer(request, resolver: resolver, buffer: buffer, continuation: continuation)
            let code = Transcript.lastCodeBlock(in: outcome.text)
            await self.finish(run: id, outcome: outcome, codeBlock: code)
            if let note = Transcript.note(for: outcome.ending) { continuation.yield(.append(note)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        run = Run(id: id, task: task, buffer: buffer)
        actionsChanged?.send()
        return stream
    }

    /// Resolves the provider and reads its answer into the buffer and the page. Never throws: a
    /// failure becomes the answer's ending, with words for the user.
    nonisolated private static func answer(
        _ request: ModelRequest, resolver: ProviderResolver, buffer: AnswerBuffer,
        continuation: AsyncThrowingStream<DetailUpdate, any Error>.Continuation
    ) async -> AnswerOutcome {
        guard case .ready(let provider) = await resolver.resolve() else {
            return AnswerOutcome(text: "", model: nil, replay: [], ending: .failed(Strings.Failures.notSetUp))
        }
        buffer.model = provider.modelName
        continuation.yield(.metadata(Transcript.metadata(model: provider.modelName, host: provider.host)))
        var replay: [AnthropicReplayBlock] = []
        var keepsReplay = true
        var finished: StopReason?
        var ending: AnswerEnding?
        do {
            for try await event in provider.stream(request) {
                switch event {
                case .text(let text):
                    buffer.append(text)
                    continuation.yield(.append(text))
                case .replay(let block):
                    if keepsReplay { replay.append(block) }
                case .discardReplay:
                    keepsReplay = false
                    replay = []
                case .finished(let reason):
                    finished = reason
                }
            }
            try Task.checkCancellation()
            switch finished {
            case .complete: ending = nil
            case .lengthLimit: ending = .lengthLimit
            case .refused: ending = .refused
            case nil: ending = .failed(Strings.Failures.cutOff)
            }
        } catch is CancellationError {
            ending = .stopped
        } catch let failure as AIFailure {
            ending = .failed(failure)
        } catch {
            ending = .failed(Strings.Failures.unexpected)
        }
        let kept = ending == nil && keepsReplay && provider.kind == .anthropic ? replay : []
        return AnswerOutcome(text: buffer.text, model: provider.modelName, replay: kept, ending: ending)
    }

    /// Records the answer when its run is still the current one, then saves a chat.
    private func finish(run id: Int, outcome: AnswerOutcome, codeBlock: String?) async {
        guard run?.id == id else { return }
        run = nil
        commit(outcome)
        lastCodeBlock = codeBlock
        actionsChanged?.send()
        await save()
    }

    /// Stops the answer that is streaming, if any, and keeps what arrived. The task's own ending is
    /// ignored afterwards.
    func interrupt() {
        guard let current = run else { return }
        run = nil
        current.task.cancel()
        let text = current.buffer.text
        commit(AnswerOutcome(text: text, model: current.buffer.model, replay: [], ending: .stopped))
        lastCodeBlock = nil
        actionsChanged?.send()
        findCodeBlock(in: text, answerCount: conversation.messages.count)
        let previous = saving
        saving = Task {
            await previous?.value
            await self.writeToStore()
        }
    }

    /// Looks for the last code block of a stopped answer off the main thread: a long answer takes a
    /// few milliseconds. Offers Copy Last Code Block once found, unless the conversation moved on.
    private func findCodeBlock(in text: String, answerCount: Int) {
        Task {
            let code = await Self.lastCodeBlock(in: text)
            guard let code, conversation.messages.count == answerCount, !isStreaming else { return }
            lastCodeBlock = code
            actionsChanged?.send()
        }
    }

    @concurrent nonisolated private static func lastCodeBlock(in text: String) async -> String? {
        Transcript.lastCodeBlock(in: text)
    }

    private func commit(_ outcome: AnswerOutcome) {
        let now = services.clock.now
        conversation.messages.append(
            ChatMessage(
                role: .assistant, text: outcome.text, date: now, model: outcome.model,
                replay: outcome.replay.isEmpty ? nil : outcome.replay, ending: outcome.ending))
        conversation.updated = now
    }

    // MARK: - Saving

    /// Saves a chat after the saves already under way. Does nothing for Ask AI and the text commands,
    /// or when the settings keep no chats.
    func save() async {
        let previous = saving
        let task = Task {
            await previous?.value
            await self.writeToStore()
        }
        saving = task
        await task.value
    }

    private func writeToStore() async {
        guard mode == .chat, conversation.hasMessages, services.settings[AISettings.retention].keepsChats else {
            return
        }
        try? await services.store.save(conversation)
    }

    // MARK: - Actions

    private func outputActions(for answer: String) -> [Action] {
        switch mode {
        case .text(let output):
            // A rewrite goes back where the text was, so the blank lines a model adds around it are dropped.
            let result = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let paste = Action.paste(result, title: output.pasteTitle)
            let copy = Action.copy(result, title: Strings.Actions.copyResult, hud: Strings.Actions.copiedResult)
            return output.pastesFirst ? [paste, copy] : [copy, paste]
        case .ask, .chat:
            return [
                .copy(answer, title: Strings.Actions.copyAnswer, hud: Strings.Actions.copiedAnswer),
                .paste(answer, title: Strings.Actions.pasteAnswer),
            ]
        }
    }

    private var stopAction: Action {
        Action(
            Strings.Actions.stop, id: "stop", icon: .symbol("stop.circle"), shortcut: KeyCombo(.period, .command),
            runPolicy: .concurrent
        ) { [weak self] _ in
            self?.interrupt()
            return .keepOpen
        }
    }

    private var regenerateAction: Action {
        Action(
            Strings.Actions.regenerate, id: "regenerate", icon: .symbol("arrow.clockwise"), shortcut: .refresh,
            runPolicy: .dropWhileRunning
        ) { [weak self] context in
            self?.prepareToRegenerate()
            context.reload()
            return .keepOpen
        }
    }

    private var continueInChatAction: Action {
        Action(
            Strings.Actions.continueInChat, id: "continue-in-chat", icon: .symbol("bubble.left.and.bubble.right"),
            shortcut: KeyCombo(.j, .command)
        ) { [weak self] _ in
            guard let self else { return .keepOpen }
            let chat = self.continuedInChat()
            await chat.save()
            return .replace(chat.page)
        }
    }

    private var newChatAction: Action {
        Action(Strings.Actions.newChat, id: "new-chat", icon: .symbol("square.and.pencil"), shortcut: .new) {
            [weak self] _ in
            guard let self else { return .keepOpen }
            let chat = AnswerSession(
                conversation: self.services.newConversation(), mode: .chat, title: Strings.Chat.newChatTitle,
                services: self.services)
            return .replace(chat.page)
        }
    }

    /// Drops the last answer so the page asks again when it reloads.
    func prepareToRegenerate() {
        interrupt()
        holdsQuestion = false
        if conversation.messages.last?.role == .assistant { conversation.messages.removeLast() }
        lastCodeBlock = nil
    }

    /// The same conversation as an AI Chat page, titled by its first question.
    func continuedInChat() -> AnswerSession {
        interrupt()
        var moved = conversation
        moved.title = moved.displayTitle
        return AnswerSession(conversation: moved, mode: .chat, title: moved.title, services: services)
    }
}

/// How an answer ended, as the page records it.
nonisolated struct AnswerOutcome: Sendable {
    var text: String
    var model: String?
    var replay: [AnthropicReplayBlock]
    var ending: AnswerEnding?
}

/// The text of an answer while it streams, readable at once from any thread.
nonisolated final class AnswerBuffer: Sendable {
    private struct State {
        var text = ""
        var model: String?
    }

    private let state = Mutex(State())

    var text: String { state.withLock { $0.text } }

    var model: String? {
        get { state.withLock { $0.model } }
        set { state.withLock { $0.model = newValue } }
    }

    func append(_ piece: String) {
        state.withLock { $0.text += piece }
    }
}
