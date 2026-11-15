/// A service one feature offers to the rest of Slick. The host wires it in at registration, so
/// features stay independent: the Snippets feature reads the clipboard through
/// ``PasteboardService/recentText(offset:)`` and never imports Clipboard History.
public enum ProvidedService: Sendable {
    /// The persistent clipboard history. While the providing feature is on, the host answers
    /// ``PasteboardService/recentText(offset:)``, and so `{clipboard offset=N}`, from it.
    case clipboardHistory(any ClipboardHistoryReader)
}

/// Reads text from a clipboard history, newest first.
public protocol ClipboardHistoryReader: Sendable {
    /// The text copied `offset` entries ago, 0 being the newest, or nil when there is none.
    @concurrent func text(offset: Int) async -> String?
}
