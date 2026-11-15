import Kit

/// The feature's settings. `nonisolated`, so code off the main actor can read them too.
nonisolated enum SystemSettings {
    /// How far Volume Up and Volume Down move the volume.
    static let volumeStep = SettingKey("volumeStep", default: VolumeStep.keys)
    /// Whether Eject All Disks also disconnects server volumes. Off by default, as unplugging a
    /// drive and leaving a server are different things.
    static let ejectsNetworkVolumes = SettingKey("ejectsNetworkVolumes", default: false)
    /// Names of disks Eject All Disks leaves alone, such as a backup drive that stays plugged in.
    static let neverEject = SettingKey("neverEject", default: [String]())
    /// The order Kill Process opens in.
    static let processSort = SettingKey("processSort", default: ProcessSort.cpu)
    /// How often the Kill Process list refreshes while it is open.
    static let processRefresh = SettingKey("processRefresh", default: ProcessRefresh.twoSeconds)
    /// Whether Kill Process lists processes without a Dock icon too. On by default: a stuck
    /// background process is a common reason to open it.
    static let showsBackgroundProcesses = SettingKey("showsBackgroundProcesses", default: true)
}

/// How far one press of Volume Up or Volume Down moves the volume.
nonisolated enum VolumeStep: String, SettingValue, CaseIterable, Sendable {
    /// One sixteenth, as the volume keys move it.
    case keys
    case fivePercent
    case tenPercent

    /// How many steps go from silent to full volume.
    var divisions: Int {
        switch self {
        case .keys: 16
        case .fivePercent: 20
        case .tenPercent: 10
        }
    }
}

/// The order of the Kill Process list.
nonisolated enum ProcessSort: String, SettingValue, CaseIterable, Sendable {
    case cpu
    case memory
    case name
}

/// How often the Kill Process list refreshes.
nonisolated enum ProcessRefresh: String, SettingValue, CaseIterable, Sendable {
    case oneSecond
    case twoSeconds
    case fiveSeconds

    var interval: Duration {
        switch self {
        case .oneSecond: .seconds(1)
        case .twoSeconds: .seconds(2)
        case .fiveSeconds: .seconds(5)
        }
    }
}
