/// What the panel does after an action or a command has run.
public enum ActionOutcome: Sendable {
    /// Closes the panel, then shows the HUD when one is given. The next summon starts at root or
    /// where the user left off, as their settings say.
    case close(hud: HUD? = nil)
    /// Keeps the panel as it is. Combine with ``ActionContext/reload()`` or
    /// ``ActionContext/showToast(_:)`` to show what changed.
    case keepOpen
    /// Pushes a page on top of the current one.
    case push(Page)
    /// Replaces the top page, so Back skips it, as after a setup form that leads to its result.
    case replace(Page)
    /// Goes back one page.
    case pop
    /// Goes back to root search.
    case popToRoot
    /// Goes back to root search with this text in the search field, as "Use Again" or "Search for
    /// This" do.
    case showRoot(query: String)
    /// Runs another command, by ID, with argument values by name. The command may belong to another
    /// feature; this is how features hand work to each other. Arguments the command does not declare
    /// are passed along too. When the command is unavailable the host shows a failure toast.
    case run(ItemID, arguments: [String: String] = [:])
    /// The handler found a permission missing while it ran, such as Automation for whichever app is
    /// frontmost. The host shows its permission card, with the reason from the manifest, and runs
    /// the action or command again once the user grants it.
    case needsPermission(Permission)
    /// Closes the panel, then shows the text in very large letters across the screen, to read a
    /// phone number or a code from across the room. Any key, any click or a switch to another app
    /// hides it. Outside the live launcher it is recorded instead of shown. The host offers this
    /// itself, as Show in Large Type, for every row and detail that represents text; return it
    /// for text that nothing on screen represents. See ``Action/showInLargeType(_:title:)``.
    case showLargeType(String)
}
