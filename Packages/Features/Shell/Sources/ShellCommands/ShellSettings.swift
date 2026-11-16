import Kit

/// The feature's settings, stored as `shell.<name>`. `nonisolated`, so code off the main actor can
/// read them.
nonisolated enum ShellSettings {
    /// The shell a command runs in. The account's login shell by default.
    static let shell = SettingKey("shell", default: ShellChoice.login)
    /// The folder a command starts in: empty for the home folder, or a path that starts with "/" or
    /// "~".
    static let workingFolder = SettingKey("workingFolder", default: "")
    /// Whether commands are saved in Shell History.
    static let keepsHistory = SettingKey("keepsHistory", default: true)
    /// How much output a page keeps.
    static let outputLimit = SettingKey("outputLimit", default: OutputLimit.twoMegabytes)
}

/// The shell a command runs in. Each runs as a login shell, so it reads the user's profile.
nonisolated enum ShellChoice: String, SettingValue, CaseIterable, Sendable {
    /// The shell the user account names, as Terminal uses.
    case login
    case zsh
    case bash
    case sh

    /// The fixed path, or nil for the login shell, which is looked up when a command runs.
    var path: String? {
        switch self {
        case .login: nil
        case .zsh: "/bin/zsh"
        case .bash: "/bin/bash"
        case .sh: "/bin/sh"
        }
    }

    /// The shell used when the account's login shell cannot be read or cannot run.
    static let fallbackPath = "/bin/zsh"
}

/// How much output a page keeps. Past the limit the page drops the oldest output and says so.
nonisolated enum OutputLimit: String, SettingValue, CaseIterable, Sendable {
    case halfMegabyte
    case oneMegabyte
    case twoMegabytes
    case eightMegabytes
    case thirtyTwoMegabytes

    var bytes: Int {
        switch self {
        case .halfMegabyte: 512 * 1024
        case .oneMegabyte: 1024 * 1024
        case .twoMegabytes: 2 * 1024 * 1024
        case .eightMegabytes: 8 * 1024 * 1024
        case .thirtyTwoMegabytes: 32 * 1024 * 1024
        }
    }
}
