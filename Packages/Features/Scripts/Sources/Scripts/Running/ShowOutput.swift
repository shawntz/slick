import Kit

/// The page that shows a finished script's whole output, for a script that failed.
enum ShowOutput {
    static func page(title: String, output: CapturedOutput) -> Page {
        let text = output.combined
        let detail = Detail(
            .text(text, monospaced: true),
            metadata: [.label(Strings.exitCodeLabel, value: String(output.exitCode))])
        let actions: [Action] = text.isEmpty ? [] : [.copy(ANSI.strip(text), title: Strings.copyOutput)]
        return .detail(DetailPage(title: Strings.outputTitle(title), detail: detail, actions: actions))
    }

    /// An action that pushes ``page(title:output:)``.
    static func action(title: String, output: CapturedOutput) -> Action {
        .push(Strings.showOutput, id: "show-output", icon: .symbol("text.alignleft")) {
            page(title: title, output: output)
        }
    }

    /// A toast button that pushes ``page(title:output:)``.
    static func toastAction(title: String, output: CapturedOutput) -> ToastAction {
        ToastAction(Strings.showOutput) { _ in .push(page(title: title, output: output)) }
    }
}
