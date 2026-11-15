/// How a command or an action was started.
public enum LaunchSource: Hashable, Sendable {
    /// From a row or a command in root search. Root records the use itself.
    case root
    /// From a row, an empty state or a detail on a page the feature pushed. The feature records the
    /// use if it keeps recents; see ``Action/recordingUse()``.
    case page
    /// From a global hotkey. The panel may be closed, so toasts show as HUDs.
    case hotkey
    /// From the fallback list. ``ActionContext/query`` holds the typed text, which also fills the
    /// first argument when the command declares one.
    case fallback
    /// From Tab in root search. ``ActionContext/query`` holds the typed text, which also fills the
    /// first argument when the command declares one.
    case tabFromRoot
    /// From a deep link.
    case deeplink
    /// From a suggestion row.
    case suggestion
    /// From another command's ``ActionOutcome/run(_:arguments:)``.
    case command
    /// From the selection hotkey, as a universal action. ``ActionContext/query`` is the selection
    /// as text.
    case selection
    /// From a keyword typed in another app, through ``ExpansionResult/runCommand(_:arguments:)``.
    case textExpansion
    /// From a button in the settings window.
    case settings
}
