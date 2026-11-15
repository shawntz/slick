import Foundation
import Kit

/// The feature's settings, stored as `clipboard.<name>`. `nonisolated`, so the monitor reads them
/// off the main thread.
nonisolated enum ClipboardSettings {
    /// True stops recording. The history stays and can still be pasted.
    static let isPaused = SettingKey("paused", default: false)
    /// How long unpinned items are kept.
    static let retention = SettingKey("retention", default: Retention.threeMonths)
    /// The most unpinned items kept. Older ones go first.
    static let maximumItems = SettingKey("maximumItems", default: 10_000)
    /// The most disk space, in megabytes, that unpinned images may take. Older images go first.
    static let imageStorageMegabytes = SettingKey("imageStorageMegabytes", default: 1_000)
    /// Bundle IDs of apps whose copies are never recorded.
    static let ignoredApps = SettingKey("ignoredApps", default: defaultIgnoredApps)
    /// What Return does on an item.
    static let primaryAction = SettingKey("primaryAction", default: PrimaryAction.paste)
    /// True moves an item to the top of the history when the user pastes or copies it from here.
    static let movesUsedItemsToTop = SettingKey("movesUsedItemsToTop", default: true)

    /// Password managers and the keychain. Most of them mark what they copy as concealed, which the
    /// pasteboard service already skips; this list catches the ones that do not.
    static let defaultIgnoredApps = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "com.lastpass.LastPass",
    ]

    /// Choices for the item cap.
    static let maximumItemChoices = [1_000, 5_000, 10_000, 50_000, 100_000]
    /// Choices for the image storage cap, in megabytes.
    static let imageStorageChoices = [250, 500, 1_000, 2_000, 5_000]

    /// Text and images larger than this are not recorded.
    static let maximumItemBytes = 10 << 20
}

/// How long unpinned items are kept.
nonisolated enum Retention: String, CaseIterable, SettingValue {
    case day
    case week
    case month
    case threeMonths = "three-months"
    case sixMonths = "six-months"
    case year
    case forever

    /// True when this keeps items for a shorter time than `other`, so choosing it deletes some.
    func keepsLess(than other: Retention) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: self) ?? 0) < (order.firstIndex(of: other) ?? 0)
    }

    /// Items copied before this moment are deleted. Nil keeps everything.
    func cutoff(now: Date, calendar: Calendar) -> Date? {
        let step: (component: Calendar.Component, value: Int)? =
            switch self {
            case .day: (.day, -1)
            case .week: (.day, -7)
            case .month: (.month, -1)
            case .threeMonths: (.month, -3)
            case .sixMonths: (.month, -6)
            case .year: (.year, -1)
            case .forever: nil
            }
        return step.flatMap { calendar.date(byAdding: $0.component, value: $0.value, to: now) }
    }
}

/// What Return does on an item.
nonisolated enum PrimaryAction: String, CaseIterable, SettingValue {
    case paste
    case copy
}

/// The limits pruning applies, read from the settings at one moment.
nonisolated struct PrunePolicy: Hashable, Sendable {
    /// Unpinned items copied before this are deleted. Nil keeps them.
    var cutoff: Date?
    /// The most unpinned items kept.
    var maximumItems: Int
    /// The most bytes unpinned images may take.
    var maximumImageBytes: Int

    /// The policy the settings give now.
    init(settings: FeatureSettings, clock: any ClockService) {
        cutoff = settings[ClipboardSettings.retention].cutoff(now: clock.now, calendar: clock.calendar)
        maximumItems = max(1, settings[ClipboardSettings.maximumItems])
        maximumImageBytes = max(1, settings[ClipboardSettings.imageStorageMegabytes]) << 20
    }

    init(cutoff: Date?, maximumItems: Int, maximumImageBytes: Int) {
        self.cutoff = cutoff
        self.maximumItems = maximumItems
        self.maximumImageBytes = maximumImageBytes
    }
}
