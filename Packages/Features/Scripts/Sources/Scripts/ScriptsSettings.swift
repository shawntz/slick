import Kit

/// The feature's settings. `nonisolated`, so code off the main actor can read them, as an inline
/// script's subtitle does.
nonisolated enum ScriptsSettings {
    /// Script folders besides the default one, as paths.
    static let folders = SettingKey("folders", default: [String]())
    /// The extra folders whose scripts may run, as paths. A folder added to ``folders`` stays off
    /// until the user adds it here.
    static let enabledFolders = SettingKey("enabledFolders", default: [String]())
    /// Command IDs of the inline scripts that run by themselves on their refresh time.
    static let refreshingInline = SettingKey("refreshingInline", default: [String]())
    static let timeout = SettingKey("timeout", default: ScriptTimeout.oneMinute)
    static let outputLimit = SettingKey("outputLimit", default: OutputLimit.oneMegabyte)
    /// The `PATH` scripts run with. Homebrew's folders come first, as in other launchers.
    static let searchPath = SettingKey("searchPath", default: defaultSearchPath)

    static let defaultSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

/// How long a script may run before it is stopped.
nonisolated enum ScriptTimeout: String, SettingValue, CaseIterable, Sendable {
    case tenSeconds
    case thirtySeconds
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case never

    var duration: Duration? {
        switch self {
        case .tenSeconds: .seconds(10)
        case .thirtySeconds: .seconds(30)
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        case .never: nil
        }
    }
}

/// How much output a script may print before it is stopped.
nonisolated enum OutputLimit: String, SettingValue, CaseIterable, Sendable {
    case quarterMegabyte
    case oneMegabyte
    case fourMegabytes
    case sixteenMegabytes

    var bytes: Int {
        switch self {
        case .quarterMegabyte: 256 * 1024
        case .oneMegabyte: 1024 * 1024
        case .fourMegabytes: 4 * 1024 * 1024
        case .sixteenMegabytes: 16 * 1024 * 1024
        }
    }
}
