extension FeatureValidator {
    /// Problems under rules that are newer than some features. They stay out of ``validate(_:)``, so
    /// a feature that passed before still passes and the host still registers it. A rule moves into
    /// `validate` once every registered feature follows it. A new feature's tests should expect this
    /// to be empty as well: `FeatureHarness.pendingIssues`.
    ///
    /// The rules now:
    /// - A hidden command that asks no confirmation sets ``Command/allowsDeepLinks`` to false. A web
    ///   page can fire a deep link, and once the user chose Always Allow for a command the link runs
    ///   it without a word. A hidden command is often one that acts at once, such as a paste.
    public static func pendingIssues(_ feature: any Feature) -> [FeatureIssue] {
        pendingIssues(commands: feature.commands)
    }

    /// The pending rules for a list of commands.
    public static func pendingIssues(commands: [Command]) -> [FeatureIssue] {
        commands.filter { !$0.showsInRoot && $0.confirmation == nil && $0.allowsDeepLinks }.map {
            FeatureIssue(
                "command \"\($0.id)\" is hidden and asks nothing, so a deep link would run it as is; "
                    + "set allowsDeepLinks to false or give it a confirmation")
        }
    }
}
