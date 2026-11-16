import Foundation
import Kit

/// What a click on a link in a detail does, on a detail page or in a list's detail pane.
///
/// A web or mail link opens at once. Any other link, a file link included, could open an app or a
/// document the reader never meant to, and a Markdown link's text need not match its target. So
/// the panel shows the full target in a toast, and only the toast's Open button opens it.
enum DetailLinks {
    /// The schemes that open at once.
    nonisolated static let schemesOpenedAtOnce: Set<String> = ["http", "https", "mailto"]

    /// True for a link that opens without asking first.
    nonisolated static func opensAtOnce(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemesOpenedAtOnce.contains(scheme)
    }

    /// The toast that shows a link's full target and opens it on its button.
    nonisolated static func askingToast(for url: URL) -> Toast {
        Toast(
            .info, HostStrings.notAWebLink, message: DisplayText.oneLine(url.absoluteString),
            action: ToastAction(HostStrings.open) { context in
                try await context.workspace.open(url)
                return .keepOpen
            })
    }

    /// Opens the link with the workspace of the feature that made the detail, or shows the toast
    /// that asks first.
    @MainActor static func open(_ url: URL, origin: RunOrigin, pipeline: RunPipeline) {
        guard opensAtOnce(url) else {
            pipeline.presenter?.showToast(askingToast(for: url), id: pipeline.makeToastID(), origin: origin)
            return
        }
        let workspace = origin.feature.workspace
        Task { try? await workspace.open(url) }
    }
}
