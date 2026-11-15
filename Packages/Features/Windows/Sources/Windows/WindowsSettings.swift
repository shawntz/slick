import Kit

/// The feature's settings. Defaults leave windows exactly where a layout puts them, with no gaps,
/// and say nothing after a command that worked.
nonisolated enum WindowsSettings {
    static let windowGap = SettingKey("windowGap", default: 0)
    static let screenGap = SettingKey("screenGap", default: 0)
    static let repeatBehavior = SettingKey("repeatBehavior", default: RepeatBehavior.cycleSizes)
    static let almostMaximizePercent = SettingKey("almostMaximizePercent", default: 90)
    static let showsLayoutName = SettingKey("showsLayoutName", default: false)

    /// The ranges the settings pane offers, which reads also clamp to.
    static let gapRange = 0...48
    static let almostMaximizeRange = 50...100

    /// The layout settings as plain values, for the service's background thread.
    static func options(_ settings: FeatureSettings) -> LayoutOptions {
        LayoutOptions(
            screenGap: Double(settings[screenGap].clamped(to: gapRange)),
            windowGap: Double(settings[windowGap].clamped(to: gapRange)),
            repeatBehavior: settings[repeatBehavior],
            almostMaximizeFraction: Double(settings[almostMaximizePercent].clamped(to: almostMaximizeRange)) / 100)
    }
}

extension RepeatBehavior: SettingValue {}

extension Int {
    fileprivate nonisolated func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
