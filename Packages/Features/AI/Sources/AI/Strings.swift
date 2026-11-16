import Foundation
import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Everything else is a plain sentence that says what will happen.
nonisolated enum Strings {
    static let featureName = "AI"
    static let featureSummary =
        "Ask a model from the launcher, chat, and rewrite selected text, with Apple's on-device model, Anthropic "
        + "or a server you run."
    static let accessibilityReason = "Read the text you select in other apps and paste results back into them."

    // MARK: - Providers

    enum Providers {
        static let anthropic = "Anthropic"
        static let onDeviceModel = "Apple On-Device Model"
    }

    // MARK: - Ask AI

    enum Ask {
        static let title = "Ask AI"
        static let keywords = ["question", "chatgpt", "claude", "llm", "model", "assistant"]
        static let placeholder = "Question"
        static let followUp = "Ask a follow-up question"
        static let firstQuestion = "Ask a question"
        static let emptyHint = "Type a question and press Return."

        static func fallback(_ text: String) -> String {
            "Ask AI about \u{201C}\(text)\u{201D}"
        }
    }

    // MARK: - Actions on an answer

    enum Actions {
        static let copyAnswer = "Copy Answer"
        static let copiedAnswer = "Copied Answer"
        static let pasteAnswer = "Paste Answer"
        static let copyResult = "Copy Result"
        static let copiedResult = "Copied Result"
        static let replaceSelection = "Replace Selection"
        static let pasteResult = "Paste Result"
        static let copyCodeBlock = "Copy Last Code Block"
        static let copiedCodeBlock = "Copied Code Block"
        static let regenerate = "Regenerate"
        static let stop = "Stop"
        static let continueInChat = "Continue in Chat"
        static let newChat = "New Chat"
    }

    // MARK: - Detail pages

    enum Detail {
        static let model = "Model"
        static let sentTo = "Sent To"
        static let thisMac = "Nothing leaves this Mac"
    }

    enum Notes {
        static let stopped = "Stopped"
        static let lengthLimit = "Answer Reached the Length Limit"
        static let lengthLimitMessage = "Choose a longer response length in AI settings, then press Regenerate."
        static let refused = "The Model Declined to Answer"
        static let refusedMessage = "Rephrase the request, or choose another model in AI settings."
        static let notSent = "Not Sent"
        static let notSentMessage = "This question has no answer yet. Press Regenerate to send it."
    }

    // MARK: - AI Chat

    enum Chat {
        static let title = "AI Chat"
        static let keywords = ["chat", "conversation", "history", "claude", "llm"]
        static let newChatCommand = "New AI Chat"
        static let newChatTitle = "New Chat"
        static let untitled = "New Chat"
        static let searchPlaceholder = "Search chats"
        static let messagePlaceholder = "Message"
        static let newChatHint = "Type a message and press Return to start."
        static let open = "Open Chat"
        static let rename = "Rename Chat"
        static let renameTitle = "Rename Chat"
        static let renameSubmit = "Rename"
        static let titleField = "Title"
        static let export = "Export as Markdown"
        static let exportDialogTitle = "Export Chat"
        static let exported = "Exported Chat"
        static let delete = "Delete Chat"
        static let deleteConfirm = "Delete"
        static let deleted = "Deleted Chat"
        static let deleteAll = "Delete All Chats"
        static let deleteAllQuestion = "Delete All Chats?"
        static let deleteAllConfirm = "Delete All"
        static let cannotUndo = "This cannot be undone."
        static let emptyTitle = "No Chats"
        static let emptyMessage = "Start a chat to ask follow-up questions. Chats appear here by day."
        static let notKeptMessage = "Chats are not kept. Choose how long to keep them in AI settings."
        static let lastChanged = "Last Message"

        static func deleteQuestion(_ title: String) -> String {
            "Delete \u{201C}\(title)\u{201D}?"
        }

        static func deletedAll(_ count: Int) -> String {
            count == 1 ? "Deleted 1 Chat" : "Deleted \(count) Chats"
        }
    }

    enum Export {
        static let you = "You"
        static let assistant = "Assistant"

        static func started(_ date: String) -> String {
            "Started \(date)."
        }
    }

    // MARK: - Commands on text

    enum TextCommands {
        static let subtitle = "Works on the text you select"
        static let tonePlaceholder = "Tone"
        static let languagePlaceholder = "Language"
        static let toneProfessional = "Professional"
        static let toneFriendly = "Friendly"
        static let toneCasual = "Casual"
        static let toneConfident = "Confident"
        static let noSelection = "No Text Selected"
        static let noSelectionMessage = "Select text in another app, then run the command again."

        static func title(_ kind: TextCommandKind) -> String {
            switch kind {
            case .improveWriting: "Improve Writing"
            case .fixSpellingAndGrammar: "Fix Spelling and Grammar"
            case .makeShorter: "Make Shorter"
            case .makeLonger: "Make Longer"
            case .changeTone: "Change Tone"
            case .summarize: "Summarize"
            case .explain: "Explain"
            case .translate: "Translate"
            }
        }

        static func keywords(_ kind: TextCommandKind) -> [String] {
            switch kind {
            case .improveWriting: ["rewrite", "edit", "polish", "ai"]
            case .fixSpellingAndGrammar: ["proofread", "typo", "spellcheck", "grammar", "ai"]
            case .makeShorter: ["shorten", "concise", "condense", "ai"]
            case .makeLonger: ["expand", "lengthen", "elaborate", "ai"]
            case .changeTone: ["tone", "professional", "friendly", "casual", "ai"]
            case .summarize: ["summarise", "summary", "tldr", "ai"]
            case .explain: ["explain this", "what does this mean", "ai"]
            case .translate: ["translation", "language", "ai"]
            }
        }

        static func translateInto(_ language: String) -> String {
            "Translate into \(language)"
        }
    }

    // MARK: - Forms

    enum Forms {
        static let deepLinkNotice =
            "A link asked to run this command. Check the text, then press the button to send it. Nothing is sent "
            + "before that."
        static let text = "Text"
        static let question = "Question"
        static let prompt = "Prompt"
        static let send = "Send"
    }

    // MARK: - Custom commands

    enum Custom {
        static let subtitle = "Your AI command"
        static let createTitle = "Create AI Command"
        static let createKeywords = ["new ai command", "prompt", "custom", "ai"]
        static let editTitle = "Edit AI Command"
        static let edit = "Edit AI Command"
        static let delete = "Delete AI Command"
        static let deleteConfirm = "Delete"
        static let deleteMessage = "This cannot be undone."
        static let deleted = "Deleted AI Command"
        static let saved = "Saved AI Command"
        static let save = "Save AI Command"
        static let name = "Name"
        static let prompt = "Prompt"
        static let promptPlaceholder = "Rewrite this as a short poem: {selection}"
        static let promptInfo =
            "Use {selection} for the selected text and {argument name=\"topic\"} for a value you type after the "
            + "name. Up to three arguments. {clipboard} and {date} work too."
        static let result = "Result"
        static let replacesLabel = "Replace the selected text when you press Return"
        static let nameTaken = "Another AI command has this name."
        static let tooManyArguments = "Use at most three arguments."
        static let unreadableTitle = "AI Commands Could Not Be Read"
        static let unreadableMessage =
            "\(AIFeature.commandsFileName) could not be read, so your own AI commands do not show. It is left as it "
            + "is. Fix or remove it, then turn AI off and on again."
        static let newerTitle = "AI Commands Are Read Only"
        static let newerMessage =
            "A newer version wrote \(AIFeature.commandsFileName). Your AI commands work, but changes to them are not "
            + "saved, so nothing in the file is lost."

        static func deleteQuestion(_ title: String) -> String {
            "Delete \u{201C}\(title)\u{201D}?"
        }

        static func placeholderMistake(_ detail: String) -> String {
            "Fix this placeholder: \(detail)."
        }
    }

    // MARK: - Setup

    enum Setup {
        static let commandTitle = "Set Up AI Provider"
        static let keywords = ["ai settings", "api key", "provider", "ollama", "anthropic"]
        static let title = "Set Up AI"
        static let saved = "AI Provider Saved"
        static let submit = "Save and Continue"
        static let provider = "Provider"
        static let anthropicKey = "Anthropic API key"
        static let anthropicKeyPlaceholder = "sk-ant-..."
        static let anthropicModel = "Anthropic model"
        static let serverAddress = "Server address"
        static let serverModel = "Server model"
        static let serverKey = "Server API key"
        static let optional = "Optional"
        static let keepsSavedKey = "Leave empty to keep the saved key"
        static let anthropicKeyMissing = "Enter your Anthropic API key. You can make one in the Anthropic Console."
        static let keyHasSpaces = "A key has no spaces. Check that you copied all of it and nothing else."
        static let serverAddressInvalid =
            "Enter an address that starts with http:// or https://, such as http://localhost:11434/v1."
        static let serverModelMissing = "Enter the model's name as the server lists it."
        static let privacy =
            "Nothing is sent until you run an AI command. Keys go to the Keychain. You can change all of this in AI "
            + "settings."

        static func intro(reason: SetupReason?) -> String {
            switch reason {
            case nil: "Choose where AI questions go."
            case .onDevice(let status): onDeviceNote(status) + " Choose another provider to continue."
            case .missingAnthropicKey: "Anthropic needs your API key before it can answer."
            case .incompleteServer: "The server needs an address and a model name before it can answer."
            }
        }

        static func onDeviceNote(_ status: OnDeviceStatus) -> String {
            switch status {
            case .available: "Apple's on-device model is ready. It needs no key and sends nothing."
            case .notEligible: "This Mac cannot run Apple's on-device model."
            case .notEnabled: "Apple's on-device model needs Apple Intelligence, which is off in System Settings."
            case .notReady: "Apple's on-device model is still getting ready. Try it again later."
            }
        }

        static func providerTitle(_ kind: ProviderKind) -> String {
            switch kind {
            case .onDevice: "Apple On-Device Model"
            case .anthropic: "Anthropic"
            case .openAICompatible: "OpenAI-Compatible Server"
            }
        }
    }

    // MARK: - Settings

    enum Settings {
        static let defaultLanguage = "English"
        static let providerSection = "Provider"
        static let provider = "Send questions to"
        static let providerInfo =
            "Apple's on-device model needs no key. Anthropic needs an API key. A server can be one you run, such as "
            + "Ollama or LM Studio."
        static let anthropicSection = "Anthropic"
        static let anthropicFooter = "Used when the provider is Anthropic."
        static let apiKey = "API key"
        static let anthropicKeyInfo = "Kept in the Keychain and sent only to api.anthropic.com."
        static let model = "Model"
        static let anthropicModelInfo =
            "Opus answers best. Sonnet is faster, and Haiku is the fastest and costs the least."
        static let serverSection = "OpenAI-Compatible Server"
        static let serverFooter = "Used when the provider is an OpenAI-compatible server."
        static let serverAddress = "Base address"
        static let serverAddressPlaceholder = "http://localhost:11434/v1"
        static let serverAddressInfo =
            "Questions go to this address with /chat/completions added. Ollama uses http://localhost:11434/v1 and LM "
            + "Studio http://localhost:1234/v1."
        static let serverModel = "Model"
        static let serverModelPlaceholder = "llama3.2"
        static let serverModelInfo = "The model's name as the server lists it."
        static let serverKeyInfo =
            "Leave it empty for a local server that needs no key. Kept in the Keychain and sent only to the base "
            + "address."
        static let answersSection = "Answers"
        static let systemPrompt = "System prompt"
        static let systemPromptInfo =
            "Sent first with every question. A change applies to new questions and chats, not to chats already "
            + "started."
        static let responseLength = "Response length"
        static let responseLengthInfo = "The longest answer a model may give. A longer limit can cost more."
        static let translateLanguage = "Translate into"
        static let translateLanguageInfo = "Translate uses this language when you do not type one."
        static let chatsSection = "Chat History"
        static let keepChats = "Keep chats"
        static let keepChatsInfo =
            "Older chats are deleted. Choosing a shorter time deletes chats past it at once, and choosing not to "
            + "keep chats deletes them all. Both ask first."
        static let deleteOlderQuestion = "Delete Older Chats?"
        static let deleteConfirm = "Delete"

        /// What a shorter time to keep chats deletes at once, for the question it asks first.
        static func retentionMessage(_ retention: ChatRetention) -> String {
            switch retention {
            case .none: "Chats will no longer be kept, and every kept chat is deleted now. This cannot be undone."
            case .day: "Chats last changed more than a day ago are deleted now. This cannot be undone."
            case .week: "Chats last changed more than a week ago are deleted now. This cannot be undone."
            case .month: "Chats last changed more than 30 days ago are deleted now. This cannot be undone."
            case .year: "Chats last changed more than a year ago are deleted now. This cannot be undone."
            case .forever: "No chat is deleted."
            }
        }
        static let deleteAllInfo = "Deletes every kept chat after you confirm."
        static let permissionsSection = "Permissions"
        static let accessibilityInfo =
            "The commands on text need it to read your selection and to replace it with the result."

        static func modelTitle(_ model: AnthropicModel) -> String {
            switch model {
            case .opus: "Claude Opus 5.5"
            case .sonnet: "Claude Sonnet 5.5"
            case .haiku: "Claude Haiku 5.5"
            case .fable: "Claude Fable 5.2"
            }
        }

        static func lengthTitle(_ length: ResponseLength) -> String {
            switch length {
            case .short: "Short"
            case .standard: "Standard"
            case .long: "Long"
            }
        }

        static func retentionTitle(_ retention: ChatRetention) -> String {
            switch retention {
            case .none: "Don't Keep Chats"
            case .day: "For 1 Day"
            case .week: "For 1 Week"
            case .month: "For 30 Days"
            case .year: "For 1 Year"
            case .forever: "Until You Delete Them"
            }
        }

        /// What leaves the Mac, and where to, for the provider chosen now. `isUnencrypted` is true for a
        /// plain `http` address on another machine.
        static func whatIsSent(provider: ProviderKind, host: String?, isUnencrypted: Bool = false) -> String {
            let start = "Nothing is sent until you run an AI command."
            switch provider {
            case .onDevice:
                return start
                    + " Answers come from Apple's on-device model, so your questions, the selected text, the clipboard "
                    + "text your own commands use and your chats stay on this Mac."
            case .anthropic, .openAICompatible:
                let destination = host ?? "the base address below, once you enter one"
                let sent =
                    start + " Then \(Brand.name) sends your question, the selected text when a command uses it, the "
                    + "clipboard text when one of your own commands uses it, and the conversation so far to "
                    + "\(destination), and nowhere else. Each request also names the model and carries the system "
                    + "prompt and the response length."
                guard isUnencrypted else { return sent }
                return sent
                    + " This address uses plain http, so all of it, the key included, crosses the network unencrypted."
            }
        }

        static func storageFooter(_ folder: String) -> String {
            "AI Chat keeps each chat as a file in \(folder)/\(AIFeature.chatsFolderName). Ask AI and the commands on "
                + "text keep nothing unless you choose Continue in Chat. Your own AI commands are in "
                + "\(folder)/\(AIFeature.commandsFileName). API keys are in the Keychain."
        }
    }

    // MARK: - Failures

    enum Failures {
        static let noInternet = AIFailure(
            "No Internet Connection", message: "Connect to the internet, then press Regenerate.")
        static let cutOff = AIFailure(
            "Answer Cut Off",
            message: "The connection closed before the answer finished. Press Regenerate to try again.")
        static let unexpected = AIFailure(
            "Something Went Wrong", message: "Press Regenerate to try again. If it keeps failing, check AI settings.")
        static let anthropicKeyRejected = AIFailure(
            "API Key Not Accepted",
            message: "Anthropic did not accept the API key. Check it in AI settings, or make a new one in the "
                + "Anthropic Console.")
        static let anthropicBilling = AIFailure(
            "Billing Problem", message: "Check the plan and billing of your Anthropic account, then try again.")
        static let permissionDenied = AIFailure(
            "Access Denied", message: "This key cannot use this model. Choose another model in AI settings.")
        static let requestTooLarge = AIFailure(
            "Conversation Too Long", message: "Start a new chat, or use less text.")
        static let badAddress = AIFailure(
            "Address Not Valid", message: "Check the base address in AI settings.")
        static let notSetUp = AIFailure(
            "No AI Provider Set Up", message: "Run Set Up AI Provider, or choose a provider in AI settings.")
        static let onDeviceFailed = AIFailure(
            "The On-Device Model Could Not Answer",
            message: "Press Regenerate to try again, or choose another provider.")
        static let onDeviceTooLong = AIFailure(
            "Conversation Too Long",
            message: "The on-device model holds only a short conversation. Start a new chat, or use less text.")
        static let onDeviceDeclined = AIFailure(
            "The Model Declined to Answer", message: "Rephrase the request, or choose another provider in AI settings.")
        static let onDeviceLanguage = AIFailure(
            "Language Not Supported", message: "The on-device model does not support this language yet.")
        static let onDeviceBusy = AIFailure(
            "The On-Device Model Is Busy", message: "Wait a moment, then press Regenerate.")
        static let onDeviceNotReady = AIFailure(
            "The On-Device Model Is Not Ready", message: "It may still be downloading. Try again later.")
        static let textTooLong = AIFailure("Text Too Long", message: "Use less text, then try again.")
        static let chatNotSaved = AIFailure("Chat Not Saved", message: "This chat could not be saved.")
        static let newerChat = AIFailure(
            "Chat Not Saved",
            message: "A newer version of this feature wrote this chat, so this one leaves it as it is.")
        static let chatGone = AIFailure("Chat Not Found", message: "It was deleted. The list shows what is left.")
        static let exportFailed = AIFailure(
            "Export Failed", message: "The file could not be written. Choose another folder and try again.")
        static let commandsUnreadable = AIFailure(
            "AI Commands Not Saved",
            message: "\(AIFeature.commandsFileName) could not be read, so it is left as it is. Fix or remove it, then "
                + "try again.")
        static let commandsNewer = AIFailure(
            "AI Commands Not Saved",
            message: "A newer version wrote \(AIFeature.commandsFileName), so this one leaves it as it is.")

        static func anthropicModelUnavailable(_ model: String) -> AIFailure {
            AIFailure(
                "Model Not Available",
                message: "Your Anthropic account cannot use \(model). Choose another model in AI settings.")
        }

        static func rateLimited(after seconds: Int?) -> AIFailure {
            let wait =
                seconds.map { $0 == 1 ? "Wait 1 second" : "Wait \($0) seconds" } ?? "Wait a minute"
            return AIFailure("Rate Limited", message: wait + ", then press Regenerate.")
        }

        static func overloaded(_ name: String) -> AIFailure {
            AIFailure(
                "\(name) Is Busy",
                message: "The service has too many requests right now. Try again in a moment, or choose another model.")
        }

        static func serverProblem(_ name: String, detail: String? = nil) -> AIFailure {
            let base = "Try again in a moment."
            return AIFailure("\(name) Had a Problem", message: detail.map { base + " It said: " + $0 } ?? base)
        }

        static func requestRefused(_ detail: String?) -> AIFailure {
            let base = "Check the model and the other choices in AI settings."
            return AIFailure("Request Not Accepted", message: detail.map { base + " It said: " + $0 } ?? base)
        }

        static func serverKeyRejected(_ host: String) -> AIFailure {
            AIFailure("API Key Not Accepted", message: "\(host) did not accept the API key. Check it in AI settings.")
        }

        static func serverModelNotFound(_ detail: String?) -> AIFailure {
            let base = "Check the base address and the model name in AI settings."
            return AIFailure("Model or Address Not Found", message: detail.map { base + " It said: " + $0 } ?? base)
        }

        static func timedOut(_ host: String) -> AIFailure {
            AIFailure("\(host) Did Not Answer", message: "Try again in a moment. A local server may still be loading.")
        }

        static func cannotFindHost(_ host: String) -> AIFailure {
            AIFailure("Cannot Find \(host)", message: "Check your internet connection and the address in AI settings.")
        }

        static func cannotConnect(_ host: String) -> AIFailure {
            AIFailure(
                "Cannot Reach \(host)",
                message: "Check that the server is running and that the base address in AI settings is right.")
        }

        static func secureConnection(_ host: String) -> AIFailure {
            AIFailure(
                "Secure Connection Failed",
                message: "The connection to \(host) could not be secured. Check the address in AI settings.")
        }

        static func insecureAddress(_ host: String) -> AIFailure {
            AIFailure(
                "Address Needs HTTPS",
                message: "macOS allows plain http only on this Mac and the local network. Use an https address for "
                    + "\(host).")
        }

        /// The server answered with a redirect to another host, which the request does not follow, so
        /// the key and the prompt never reach it. The base address is the one setting that can be
        /// wrong; Anthropic's address is fixed.
        static func redirectRefused(from host: String, to target: URL, checksAddress: Bool) -> AIFailure {
            let other = DisplayText.oneLine(target.host(percentEncoded: false) ?? target.absoluteString)
            let next = checksAddress ? "Check the base address in AI settings." : "Try again in a moment."
            return AIFailure(
                "Request Not Forwarded",
                message: "\(host) tried to send the request on to \(other), so it was not sent there. " + next)
        }

        static func requestFailed(_ host: String) -> AIFailure {
            AIFailure(
                "Request to \(host) Failed", message: "Check your connection and AI settings, then press Regenerate.")
        }
    }

    // MARK: - Simulated model

    enum Simulated {
        /// What the stand-in for the on-device model answers in scenarios and self-tests.
        static let answer =
            "This is a sample answer from the simulated on-device model. In the app, Apple's model answers here, "
            + "on this Mac."
    }
}
