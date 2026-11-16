extension FeatureValidator {
    /// Problems under rules that are newer than some features. They stay out of ``validate(_:)``, so
    /// a feature that passed before still passes and the host still registers it. A rule moves into
    /// `validate` once every registered feature follows it. A new feature's tests should expect this
    /// to be empty as well: `FeatureHarness.pendingIssues`.
    ///
    /// No rule is pending now. The last one, that a hidden command which asks nothing stays out of
    /// deep links, moved into ``validate(commands:manifest:)`` once every feature followed it.
    public static func pendingIssues(_ feature: any Feature) -> [FeatureIssue] {
        pendingIssues(commands: feature.commands)
    }

    /// The pending rules for a list of commands.
    public static func pendingIssues(commands: [Command]) -> [FeatureIssue] {
        []
    }
}
