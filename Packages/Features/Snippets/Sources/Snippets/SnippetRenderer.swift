import Kit
import KitTemplates

/// Fills in a snippet's placeholders with the template engine: dates and times from the feature's
/// clock, the clipboard and earlier clipboard entries from the pasteboard service, the selection,
/// arguments, other snippets by name, a UUID, and where the cursor goes.
nonisolated enum SnippetRenderer {
    /// Renders off the main thread. `texts` holds every snippet's text by name, for
    /// `{snippet name="..."}`; `arguments` holds values by ``TemplateArgument/key``.
    @concurrent static func render(
        _ text: String, arguments: [String: String] = [:], texts: [String: String], context: FeatureContext
    ) async -> RenderedTemplate {
        let environment = TemplateEnvironment(context: context, arguments: arguments) { name in texts[name] }
        return await Template(text).render(in: environment)
    }
}
