import Foundation
import Kit

/// AI Chat's list: kept conversations in sections by day, newest first, with a preview beside them.
/// The host filters by title and first question.
final class ChatList: ListSource {
    nonisolated static let namespace = "ai-chat"

    private let services: AnswerServices
    private let startChat: @MainActor @Sendable () async -> ActionOutcome
    private var conversations: [String: Conversation] = [:]

    /// - Parameter startChat: Opens a new chat, or the setup form first when no provider is ready.
    init(services: AnswerServices, startChat: @escaping @MainActor @Sendable () async -> ActionOutcome) {
        self.services = services
        self.startChat = startChat
    }

    var changes: ChangeSignal? { services.store.changes }
    let reloadsOnSettings: [AnySettingKey] = [AISettings.retention.erased]

    func load(_ request: ListRequest) async throws -> ListResult {
        try await services.pruneChats()
        let all = try await services.store.all()
        let sections = await Self.sections(all, clock: services.clock)
        conversations = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keeps = services.settings[AISettings.retention].keepsChats
        return ListResult(sections: sections, emptyState: keeps ? nil : notKeptState)
    }

    func actions(for row: Row) -> [Action] {
        let id = row.id.key
        let title = conversations[id]?.displayTitle ?? row.title
        return [
            Action(Strings.Chat.open, id: "open", icon: .symbol("bubble.left.and.bubble.right")) { [weak self] _ in
                guard let self else { return .keepOpen }
                return .push(try await self.session(for: id).page)
            },
            newChatAction,
            Action(Strings.Chat.rename, id: "rename", icon: .symbol("pencil"), shortcut: .edit) { [weak self] _ in
                guard let self else { return .keepOpen }
                return .push(.form(self.renameForm(try await self.conversation(id))))
            },
            Action(
                Strings.Chat.export, id: "export", icon: .symbol("square.and.arrow.down"),
                shortcut: KeyCombo(.s, .command)
            ) {
                [weak self] context in
                guard let self else { return .keepOpen }
                return try await self.export(try await self.conversation(id), context: context)
            },
            Action(
                Strings.Chat.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
                confirmation: Confirmation(
                    Strings.Chat.deleteQuestion(title), message: Strings.Chat.cannotUndo,
                    confirmTitle: Strings.Chat.deleteConfirm, isDestructive: true)
            ) { [weak self] context in
                guard let self else { return .keepOpen }
                try await self.services.store.delete(id: id)
                context.showToast(.success(Strings.Chat.deleted))
                return .keepOpen
            },
            deleteAllAction,
        ]
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let conversation = conversations[row.id.key] else { return nil }
        return await Self.preview(conversation)
    }

    // MARK: - Pieces

    var emptyState: EmptyState {
        EmptyState(
            icon: .symbol("bubble.left.and.bubble.right"), title: Strings.Chat.emptyTitle,
            message: Strings.Chat.emptyMessage, actions: [newChatAction])
    }

    private var notKeptState: EmptyState {
        EmptyState(
            icon: .symbol("bubble.left.and.bubble.right"), title: Strings.Chat.emptyTitle,
            message: Strings.Chat.notKeptMessage, actions: [newChatAction])
    }

    private var newChatAction: Action {
        Action(Strings.Actions.newChat, id: "new-chat", icon: .symbol("square.and.pencil"), shortcut: .new) {
            [startChat] _ in
            await startChat()
        }
    }

    var deleteAllAction: Action {
        Action(
            Strings.Chat.deleteAll, id: "delete-all", icon: .symbol("trash"), shortcut: .removeAll, style: .destructive,
            confirmation: Confirmation(
                Strings.Chat.deleteAllQuestion, message: Strings.Chat.cannotUndo,
                confirmTitle: Strings.Chat.deleteAllConfirm,
                isDestructive: true)
        ) { [store = services.store] context in
            let count = try await store.deleteAll()
            context.showToast(.success(Strings.Chat.deletedAll(count)))
            return .keepOpen
        }
    }

    private func conversation(_ id: String) async throws -> Conversation {
        guard let conversation = try await services.store.conversation(id: id) else { throw Strings.Failures.chatGone }
        return conversation
    }

    private func session(for id: String) async throws -> AnswerSession {
        let conversation = try await conversation(id)
        return AnswerSession(
            conversation: conversation, mode: .chat, title: conversation.displayTitle, services: services,
            sendsOnOpen: false)
    }

    private func renameForm(_ conversation: Conversation) -> FormPage {
        FormPage(
            title: Strings.Chat.renameTitle,
            fields: [
                .text("title", title: Strings.Chat.titleField, initial: conversation.displayTitle, isRequired: true)
            ],
            submitTitle: Strings.Chat.renameSubmit
        ) { [store = services.store] values, _ in
            var renamed = try await store.conversation(id: conversation.id) ?? conversation
            renamed.title = Transcript.oneLine(values.text("title"), limit: 120)
            renamed.hasCustomTitle = true
            try await store.save(renamed)
            return .pop
        }
    }

    private func export(_ conversation: Conversation, context: ActionContext) async throws -> ActionOutcome {
        let request = SaveDialogRequest(
            title: Strings.Chat.exportDialogTitle, suggestedName: Transcript.fileName(for: conversation),
            allowedTypes: ["md"])
        guard let url = await context.fileDialogs.chooseSaveLocation(request) else { return .keepOpen }
        try await Self.write(conversation, clock: context.clock, to: url)
        context.showToast(.success(Strings.Chat.exported))
        return .keepOpen
    }

    // MARK: - Off the main thread

    @concurrent nonisolated private static func write(
        _ conversation: Conversation, clock: any ClockService, to url: URL
    )
        async throws
    {
        do {
            try Data(Transcript.export(conversation, clock: clock).utf8).write(to: url, options: .atomic)
        } catch {
            throw Strings.Failures.exportFailed
        }
    }

    @concurrent nonisolated static func sections(_ conversations: [Conversation], clock: any ClockService) async
        -> [ListSection]
    {
        let days = DaySections(clock: clock, direction: .past)
        return days.sections(conversations, date: \.updated) { conversation in
            let question = conversation.messages.first { $0.role == .user }
            return Row(
                id: ItemID(namespace, conversation.id), title: conversation.displayTitle,
                subtitle: conversation.lastAnswer.map(Transcript.preview),
                icon: .symbol("bubble.left.and.bubble.right"),
                accessories: [.date(conversation.updated)],
                keywords: question.map { [Transcript.title(from: $0.label ?? $0.text, limit: 200)] } ?? [],
                memory: .never)
        }
    }

    @concurrent nonisolated private static func preview(_ conversation: Conversation) async -> Detail {
        let text = Transcript.render(conversation.messages)
        let shown = text.utf8.count > 20_000 ? String(text.prefix(10_000)) + "\n\n…" : text
        return Detail(.markdown(shown), metadata: [.date(Strings.Chat.lastChanged, conversation.updated)])
    }
}
