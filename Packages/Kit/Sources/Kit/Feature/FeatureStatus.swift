/// What a feature's background work wants the user to know. See ``Feature/status``.
public struct FeatureStatus: Hashable, Sendable {
    /// How serious the status is.
    public enum Level: Hashable, Sendable {
        /// Something the user may like to know, such as "Paused while a password field is focused".
        case info
        /// Part of the feature is not working until the user acts.
        case warning
        /// The feature failed, such as a history that cannot be written.
        case failure
    }

    public var level: Level
    public var title: String
    public var message: String?
    /// Permissions the user can grant to fix it. Settings shows a Grant button for each missing one,
    /// which runs the host's grant flow with the reason from the manifest.
    public var requires: [Permission]

    public init(_ level: Level, _ title: String, message: String? = nil, requires: [Permission] = []) {
        self.level = level
        self.title = title
        self.message = message
        self.requires = requires
    }
}
