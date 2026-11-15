/// Reads what is selected in the frontmost app, for universal actions and the `{selection}`
/// placeholder.
public protocol SelectionService: Sendable {
    /// The selection: files in Finder, or text and URLs elsewhere. Nil when nothing is selected or
    /// ``Permission/accessibility`` is missing. Never prompts. Call it only in response to the user.
    @concurrent func currentSelection() async -> Selection?
}
