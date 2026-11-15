import Kit

/// Kill Process.
extension SystemFeature {
    var processCommands: [Command] {
        [
            Command(
                id: "kill-process", title: Strings.Processes.title, icon: .symbol("xmark.octagon"),
                keywords: Strings.Processes.keywords
            ) { context in
                // A new list each time, so CPU use is measured from this opening on.
                let list = ProcessList(table: self.processes, settings: context.settings, locale: context.clock.locale)
                return .push(
                    .list(
                        ListPage(
                            list, searchPlaceholder: Strings.Processes.searchPlaceholder, filter: list.dropdown,
                            emptyState: EmptyState(icon: .symbol("checkmark.circle"), title: Strings.Processes.empty))))
            }
        ]
    }
}
