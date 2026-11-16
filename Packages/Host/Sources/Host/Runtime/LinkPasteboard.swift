import Foundation
import Kit

/// The pasteboard a run gets when a link started it or opened the panel session it started in.
///
/// It copies as the real one does, but a paste only copies and then throws a failure that says
/// so. A link never makes this app active, so the app in front can still be the web page that
/// fired the link, and Command-V would hand that page the text. The user pastes it themselves
/// where they want it.
nonisolated struct LinkPasteboard: PasteboardService {
    let base: any PasteboardService

    init(wrapping base: any PasteboardService) {
        self.base = base
    }

    /// The failure a paste throws after it copied.
    static let refusal = ActionFailure(HostStrings.copiedNotPasted, message: HostStrings.copiedNotPastedMessage)

    func copy(_ content: PasteboardContent, options: CopyOptions) async {
        await base.copy(content, options: options)
    }

    func paste(_ content: PasteboardContent, charactersAfterCursor: Int) async throws {
        await base.copy(content, options: [])
        throw Self.refusal
    }

    @concurrent func read() async -> PasteboardEntry? {
        await base.read()
    }

    @concurrent func recentText(offset: Int) async -> String? {
        await base.recentText(offset: offset)
    }

    var changeCount: Int { base.changeCount }

    func entries() -> AsyncStream<PasteboardEntry> {
        base.entries()
    }
}
