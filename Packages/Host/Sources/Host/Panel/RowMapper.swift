import AppKit
import Kit
import KitHosting
import LauncherUI

/// Turns Kit rows into LauncherUI rows: resolved text, highlights in UTF-16 offsets, accessories
/// and icons.
///
/// Icons come from the ``IconProvider`` by lookup only. An icon that is not ready maps to nil, which
/// the list draws as a placeholder; the page sets the image when the provider signals. Nothing here
/// waits, reads the disk or decodes.
@MainActor public final class RowMapper {
    public let icons: any IconProvider
    /// Resolves adaptive icons. The controller keeps it in step with the panel's appearance.
    public var isDark = false
    /// The size list icons are drawn at.
    public var rowIconSize = IconSize(points: 28, scale: 2)
    /// The size accessory icons are drawn at.
    public var accessoryIconSize = IconSize(points: 16, scale: 2)
    /// The theme the panel draws with, for subtitle colors. The controller keeps it current.
    public var resolvedTheme: ResolvedTheme?
    private let clock: any ClockService

    public init(icons: any IconProvider, clock: any ClockService) {
        self.icons = icons
        self.clock = clock
    }

    /// The list row for a Kit row. `highlights` replaces the row's own `titleHighlights` when given.
    public func listRow(_ row: Row, highlights: [Range<Int>]? = nil, now: Date? = nil) -> ListRow {
        var accessories: [RowAccessory] = []
        if !row.accessories.isEmpty {
            let reference = now ?? clock.now
            accessories.reserveCapacity(row.accessories.count)
            for accessory in row.accessories {
                if let mapped = self.accessory(accessory, now: reference) { accessories.append(mapped) }
            }
        }
        return ListRow(
            id: row.id.engineKey, title: row.title, titleHighlights: Self.ranges(highlights ?? row.titleHighlights),
            subtitle: row.subtitle ?? "", accessories: accessories, icon: image(row.icon),
            subtitleColor: row.subtitleColor == nil ? nil : subtitleColor(for: row))
    }

    /// Glass rule 5's least contrast for secondary text over the glass.
    public static let subtitleContrast = 3.0

    /// The color a row's subtitle draws in: its ``Row/subtitleColor`` moved toward the theme's
    /// title color until it reaches ``subtitleContrast`` over the glass, by the theme's own
    /// legibility rule. Nil for the theme's own subtitle color. ``listRow(_:highlights:now:)``
    /// passes it to the list.
    public func subtitleColor(for row: Row) -> CGColor? {
        guard let color = row.subtitleColor, let theme = resolvedTheme else { return nil }
        return theme.legible(Self.themeColor(color).cgColor(in: theme.appearance), minimumRatio: Self.subtitleContrast)
    }

    /// The list icon for a Kit icon, or nil when there is none or it is not ready.
    public func image(_ icon: Icon?) -> CGImage? {
        guard let icon else { return nil }
        return icons.image(for: icon, size: rowIconSize, isDark: isDark)
    }

    /// The small icon for an action or a card row.
    public func smallImage(_ icon: Icon?) -> CGImage? {
        guard let icon else { return nil }
        return icons.image(for: icon, size: accessoryIconSize, isDark: isDark)
    }

    /// The card icon for an action: an SF Symbol by name, or a looked-up image.
    public func cardIcon(_ icon: Icon?) -> CardIcon? {
        guard let icon else { return nil }
        if case .symbol(let name, _) = icon { return .symbol(name) }
        return smallImage(icon).map(CardIcon.image)
    }

    /// The SF Symbol name of an icon, for an empty state.
    public static func symbolName(_ icon: Icon?) -> String? {
        if case .symbol(let name, _) = icon { return name }
        return nil
    }

    func accessory(_ accessory: Accessory, now: Date) -> RowAccessory? {
        switch accessory {
        case .text(let text, _): .text(text)
        case .tag(let text, let color): .tag(text, color: Self.themeColor(color ?? .secondary))
        case .date(let date): .text(Self.relative(date, now: now))
        case .icon(let icon, _): icons.image(for: icon, size: accessoryIconSize, isDark: isDark).map(RowAccessory.icon)
        case .shortcut(let combo): .keycaps(Self.keycaps(combo))
        }
    }

    // MARK: Pure helpers

    /// Kit ranges as LauncherUI highlight ranges.
    public nonisolated static func ranges(_ ranges: [Range<Int>]) -> [HighlightRange] {
        guard !ranges.isEmpty else { return [] }
        return ranges.map { HighlightRange(location: $0.lowerBound, length: $0.count) }
    }

    /// One keycap per modifier, in the order macOS draws them, then the key.
    public nonisolated static func keycaps(_ combo: KeyCombo) -> [String] {
        var keys: [String] = []
        if combo.modifiers.contains(.function) { keys.append("fn") }
        if combo.modifiers.contains(.control) { keys.append("⌃") }
        if combo.modifiers.contains(.option) { keys.append("⌥") }
        if combo.modifiers.contains(.shift) { keys.append("⇧") }
        if combo.modifiers.contains(.command) { keys.append("⌘") }
        keys.append(combo.key.symbol)
        return keys
    }

    /// A Kit colour as a theme colour. Semantic colours follow the system's.
    public nonisolated static func themeColor(_ color: KitColor) -> ThemeColor {
        switch color {
        case .rgba(let red, let green, let blue, let alpha):
            return ThemeColor(red: red, green: green, blue: blue, alpha: alpha)
        case .semantic(let semantic):
            switch semantic {
            case .primary: return ThemeColor(.label)
            case .secondary: return ThemeColor(.secondaryLabel)
            default: return ThemeColor(ThemeColor.System(rawValue: semantic.rawValue) ?? .gray)
            }
        }
    }

    /// A date relative to now, as accessories show it: "now", "5m", "3h", "2d", "3w", "4mo", "1y",
    /// with "in" before a future date.
    public nonisolated static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let magnitude = abs(seconds)
        guard magnitude >= 60 else { return "now" }
        let text: String
        switch magnitude {
        case ..<3600: text = "\(Int(magnitude / 60))m"
        case ..<86_400: text = "\(Int(magnitude / 3600))h"
        case ..<(86_400 * 7): text = "\(Int(magnitude / 86_400))d"
        case ..<(86_400 * 30): text = "\(Int(magnitude / (86_400 * 7)))w"
        case ..<(86_400 * 365): text = "\(Int(magnitude / (86_400 * 30)))mo"
        default: text = "\(Int(magnitude / (86_400 * 365)))y"
        }
        return seconds < 0 ? "in " + text : text
    }
}
