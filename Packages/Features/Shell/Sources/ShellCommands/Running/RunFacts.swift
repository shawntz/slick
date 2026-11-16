import Foundation
import Kit

/// How a run ended.
nonisolated enum RunEnding: Hashable, Sendable {
    /// The shell exited with this status. A shell killed by a signal reports 128 plus its number.
    case exit(Int32)
    /// The user stopped it, or the feature was turned off.
    case stopped
    /// The shell could not start, for this reason.
    case couldNotStart(String)
}

/// What a run's page shows besides the output. Built on the main actor and handed to
/// ``RunOutput``, which makes the metadata whenever the page needs it.
nonisolated struct RunFacts: Hashable, Sendable {
    var command: String
    var shellName: String
    var folder: String
    var startedAt: Date
    var outputLimit: OutputLimit
    /// Nil while the command runs.
    var ending: RunEnding?
    /// Seconds from start to end. Nil while the command runs.
    var runTime: TimeInterval?
    var locale: Locale

    init(command: ShellCommand, setup: RunSetup, startedAt: Date, locale: Locale) {
        self.command = DisplayText.oneLine(command.trimmed)
        shellName = setup.shellName
        folder = setup.folderForDisplay
        self.startedAt = startedAt
        outputLimit = setup.outputLimit
        self.locale = locale
    }

    /// The metadata: the command, where it runs, when it started, its status, its run time once it
    /// ended, a note when the start of the output was dropped, and last, a note that the command gets
    /// no input.
    func metadata(droppedBytes: Int) -> [MetadataItem] {
        var items: [MetadataItem] = [
            .label(Strings.Page.commandLabel, value: command),
            .label(Strings.Page.shellLabel, value: shellName),
            .label(Strings.Page.folderLabel, value: folder),
            .date(Strings.Page.startedLabel, startedAt),
            status,
        ]
        if let runTime {
            items.append(.label(Strings.Page.runTimeLabel, value: Strings.duration(runTime, locale: locale)))
        }
        if droppedBytes > 0 {
            items.append(.label(Strings.Page.outputLabel, value: Strings.Page.outputDropped(outputLimit)))
        }
        items.append(.separator)
        items.append(.label(Strings.Page.inputLabel, value: Strings.Page.inputNote))
        return items
    }

    private var status: MetadataItem {
        let label = Strings.Page.statusLabel
        switch ending {
        case nil:
            return .label(label, value: Strings.Page.statusRunning, icon: .symbol("hourglass"))
        case .exit(0):
            return .label(label, value: Strings.Page.statusExited(0), icon: .symbol("checkmark.circle", tint: .green))
        case .exit(let code):
            return .label(label, value: Strings.Page.statusExited(code), icon: .symbol("xmark.circle", tint: .red))
        case .stopped:
            return .label(label, value: Strings.Page.statusStopped, icon: .symbol("stop.circle"))
        case .couldNotStart(let reason):
            return .label(
                label, value: Strings.Page.statusCouldNotStart(reason), icon: .symbol("xmark.circle", tint: .red))
        }
    }
}
