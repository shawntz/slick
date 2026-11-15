import AppKit

/// Finds and colours `{...}` placeholders in form text, such as `{clipboard}` or `{date}` in a
/// snippet. A placeholder is a brace pair with no brace or line break inside.
///
/// The colour is the theme's accent, moved toward the text colour until it reaches 4.5:1 over the
/// glass, with a faint fill behind it. While a field edits, the colours are temporary attributes
/// of its layout manager, so they never become part of the value.
enum PlaceholderHighlighter {
    /// The placeholders in `text`, as UTF-16 ranges, braces included.
    nonisolated static func ranges(in text: String) -> [NSRange] {
        let utf16 = Array(text.utf16)
        var ranges: [NSRange] = []
        var open: Int?
        for (index, unit) in utf16.enumerated() {
            switch unit {
            case 0x7B: open = index
            case 0x7D:
                if let start = open, index > start + 1 {
                    ranges.append(NSRange(location: start, length: index - start + 1))
                }
                open = nil
            case 0x0A, 0x0D: open = nil
            default: break
            }
        }
        return ranges
    }

    /// `range` clamped to a text of `length` UTF-16 units.
    nonisolated static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    /// The colours a placeholder gets.
    static func attributes(_ theme: ResolvedTheme) -> [NSAttributedString.Key: Any] {
        let color = NSColor(cgColor: theme.legible(theme.accent)) ?? .labelColor
        return [.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.12)]
    }

    /// `text` in `font` and `color`, with its placeholders coloured.
    static func attributed(_ text: String, font: NSFont, color: NSColor, theme: ResolvedTheme)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let highlight = attributes(theme)
        for range in ranges(in: text) { result.addAttributes(highlight, range: range) }
        return result
    }

    /// Colours the placeholders of a TextKit 1 text view with temporary attributes.
    static func apply(to textView: NSTextView, theme: ResolvedTheme) {
        guard let layoutManager = textView.layoutManager else { return }
        clear(textView)
        let highlight = attributes(theme)
        for range in ranges(in: textView.string) {
            layoutManager.addTemporaryAttributes(highlight, forCharacterRange: range)
        }
    }

    /// Removes every placeholder colour from a text view.
    static func clear(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
    }
}
