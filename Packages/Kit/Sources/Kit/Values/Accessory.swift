import Foundation

/// Something shown at the trailing edge of a row: a short text, a colored tag, a date, an icon or a
/// shortcut. Keep to two or three per row; the host drops the ones that do not fit.
public enum Accessory: Hashable, Sendable, Codable {
    /// Plain text, such as a count or a file size.
    case text(String, color: KitColor? = nil)
    /// Text in a colored capsule.
    case tag(String, color: KitColor? = nil)
    /// A date the host shows relative to now, such as "now", "5m" or "3d".
    case date(Date)
    /// A small icon with an optional tooltip.
    case icon(Icon, tooltip: String? = nil)
    /// A key combination drawn as keycaps.
    case shortcut(KeyCombo)
}
