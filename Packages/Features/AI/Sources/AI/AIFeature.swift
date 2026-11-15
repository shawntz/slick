import Foundation
import Kit
import KitStorage

/// Ask a model from the launcher, with a provider the user chooses.
///
/// - Ask AI takes the root query on Tab or as a fallback, streams the answer into a detail page and
///   takes follow-ups.
/// - AI Chat keeps conversations, one JSON file each in the feature's `Chats` folder, listed by day.
/// - Eight commands work on selected text, as commands and as universal actions, and the user can
///   write their own in Kit's template language; those live in `commands.json`.
/// - Providers: Apple's on-device model, the default when the Mac has it; the Anthropic API with a
///   key in the Keychain; or any server that speaks the OpenAI chat completions format.
///
/// Nothing is sent anywhere, and nothing is read, until the user runs an AI command. When a command
/// finds no provider ready, it shows a short setup form and then the answer.
public final class AIFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "ai", name: Strings.featureName, icon: .symbol("sparkles"), summary: Strings.featureSummary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.accessibilityReason)])

    /// The commands file's name in the data folder.
    nonisolated static let commandsFileName = "commands.json"
    /// The chats folder's name in the data folder.
    nonisolated static let chatsFolderName = "Chats"

    let context: FeatureContext
    let onDevice: any OnDeviceModelService
    let resolver: ProviderResolver
    let store: ConversationStore
    let services: AnswerServices
    let commandFile: JSONFileStore<CustomCommandFile>
    public let declarationChanges: ChangeSignal? = ChangeSignal()

    /// The user's own commands, read from `commands.json` at activation, with their prompts parsed.
    var preparedCommands: [PreparedCommand] = []
    /// Whether `commands.json` could be read, and so whether saving is safe.
    var commandFileState = CommandFileState.readable

    /// The user's own commands, in the order the file lists them.
    var customCommands: [CustomCommand] { preparedCommands.map(\.command) }

    /// Tells settings when the user's commands file cannot be used as it is.
    public var status: FeatureStatus? { commandFileStatus }

    private(set) lazy var chatList = ChatList(services: services) { [weak self] in
        await self?.startChat() ?? .keepOpen
    }
    private var watcher: Task<Void, Never>?
    private var loading: Task<Void, Never>?

    /// Does no I/O. The on-device model, the Keychain and the network are not touched until a
    /// command runs.
    public init(context: FeatureContext) {
        self.context = context
        onDevice = context.service(OnDeviceModelKey.self)
        resolver = ProviderResolver(
            settings: context.settings, secrets: context.secrets, http: context.http, onDevice: onDevice)
        store = ConversationStore(
            folder: context.storage.dataDirectory.appending(path: Self.chatsFolderName, directoryHint: .isDirectory))
        services = AnswerServices(resolver: resolver, store: store, settings: context.settings, clock: context.clock)
        commandFile = JSONFileStore(url: context.storage.dataFile(Self.commandsFileName))
    }

    var settings: FeatureSettings { context.settings }

    // MARK: - Lifecycle

    /// Reads the user's commands and deletes chats past their time, both off the main thread. Neither
    /// reads a chat's contents, the selection, a key or the network.
    public func activate() async {
        watcher?.cancel()
        loading?.cancel()
        let changes = settings.changes(
            ofAny: AISettings.destinationKeys + [AISettings.retention.erased, AISettings.translateLanguage.erased])
        watcher = Task { [weak self] in
            for await name in changes {
                await self?.settingChanged(name)
            }
        }
        loading = Task { [weak self] in
            await self?.loadCustomCommands()
            try? await self?.pruneChats()
        }
    }

    public func deactivate() async {
        watcher?.cancel()
        watcher = nil
        loading?.cancel()
        await loading?.value
        loading = nil
    }

    /// Waits for the work activation started. For tests.
    func waitUntilLoaded() async {
        await loading?.value
    }

    private func settingChanged(_ name: String) async {
        if name == AISettings.retention.name { try? await pruneChats() }
        declarationChanges?.send()
    }

    /// Deletes chats older than the settings keep them, or all of them when the settings keep none.
    func pruneChats() async throws {
        try await services.pruneChats()
    }

    // MARK: - Declarations

    public var commands: [Command] {
        [askCommand, chatCommand, newChatCommand] + textCommands + [createCommand, setupCommand]
            + customCommandEntries
    }

    public var universalActions: [UniversalActionProvider] { [textActionProvider] }

    // MARK: - Ask AI

    var askCommand: Command {
        Command(
            id: "ask", title: Strings.Ask.title, icon: .symbol("sparkles"), keywords: Strings.Ask.keywords,
            arguments: [CommandArgument("prompt", placeholder: Strings.Ask.placeholder, isOptional: true)],
            fallback: Fallback { Strings.Ask.fallback($0) }, takesRootQueryOnTab: true
        ) { [weak self] context in
            guard let self else { return .keepOpen }
            let typed = context.arguments["prompt"].flatMap { $0.isEmpty ? nil : $0 } ?? context.query
            let prompt = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard prompt.utf8.count <= TextInput.maximumBytes else { throw Strings.Failures.textTooLong }
            let services = self.services
            if context.launch == .deeplink {
                return .push(
                    .form(
                        self.typedTextForm(title: Strings.Ask.title, field: Strings.Forms.question, initial: prompt) {
                            Self.askSession($0, services: services)
                        }))
            }
            // With nothing typed, the page opens empty and its field takes the first question.
            return await self.open(replacing: false) { Self.askSession(prompt, services: services).page }
        }
    }

    /// An Ask AI page for a question, or an empty one that waits for the first question.
    static func askSession(_ question: String, services: AnswerServices) -> AnswerSession {
        var conversation = services.newConversation()
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            conversation.messages = [ChatMessage(role: .user, text: question, date: services.clock.now)]
        }
        return AnswerSession(conversation: conversation, mode: .ask, title: Strings.Ask.title, services: services)
    }

    // MARK: - AI Chat

    var chatCommand: Command {
        Command(
            id: "chat", title: Strings.Chat.title, icon: .symbol("bubble.left.and.bubble.right"),
            keywords: Strings.Chat.keywords
        ) { [weak self] _ in
            guard let self else { return .keepOpen }
            return .push(.list(self.chatPage))
        }
    }

    var newChatCommand: Command {
        Command(
            id: "new-chat", title: Strings.Chat.newChatCommand, icon: .symbol("square.and.pencil"),
            keywords: Strings.Chat.keywords
        ) { [weak self] _ in
            await self?.startChat() ?? .keepOpen
        }
    }

    /// A new chat, after the setup form when no provider is ready.
    func startChat() async -> ActionOutcome {
        let services = services
        return await open(replacing: false) {
            AnswerSession(
                conversation: services.newConversation(), mode: .chat, title: Strings.Chat.newChatTitle,
                services: services
            ).page
        }
    }

    var chatPage: ListPage {
        ListPage(
            chatList, title: Strings.Chat.title, searchPlaceholder: Strings.Chat.searchPlaceholder, showsDetail: true,
            emptyState: chatList.emptyState)
    }

    // MARK: - Opening answers

    /// The page for what the user asked when a provider is ready, else the setup form, which then
    /// replaces itself with that page.
    func open(replacing: Bool, page: @escaping @MainActor () -> Page) async -> ActionOutcome {
        switch await resolver.resolve() {
        case .ready:
            return replacing ? .replace(page()) : .push(page())
        case .needsSetup(let reason):
            let form = await setupForm(reason: reason) { .replace(page()) }
            return replacing ? .replace(.form(form)) : .push(.form(form))
        }
    }
}
