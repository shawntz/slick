import AppKit

/// How big Large Type draws, as fractions of the screen it shows on.
nonisolated public struct LargeTypeMetrics: Sendable, Equatable {
    /// The widest the text may be, as a fraction of the screen's width.
    public var widthFraction: Double = 0.8
    /// The tallest the text may be, as a fraction of the screen's height.
    public var heightFraction: Double = 0.7
    /// The largest font size, as a fraction of the screen's height, so one digit does not fill
    /// the screen.
    public var maximumSizeFraction: Double = 0.3
    /// Text that fits on its lines at this size or larger, as a fraction of the screen's height,
    /// is drawn without wrapping, so a phone number or a code stays on one line. Smaller wraps.
    public var unwrappedFraction: Double = 0.08
    /// The smallest font size. Text that does not fit at this size is cut with an ellipsis.
    public var minimumSize: Double = 28
    /// The space around the text inside the backing, as a fraction of the font size.
    public var paddingFraction: Double = 0.3
    public var minimumPadding: Double = 24
    public var maximumPadding: Double = 64
    /// The most characters shown. Longer text is cut with an ellipsis.
    public var maximumCharacters: Int = 1_000

    public init() {}

    public static let standard = LargeTypeMetrics()
}

/// Where and how large Large Type draws a text on one screen: as large as fits in about 80 percent
/// of the screen's width, on the text's own lines when that is large enough, wrapped otherwise.
///
/// Pure layout: it measures with AppKit's text system and touches no window, so tests can try any
/// text on any screen size.
nonisolated public struct LargeTypeLayout: Sendable, Equatable {
    /// The text drawn: the text given, cut to ``LargeTypeMetrics/maximumCharacters``.
    public var text: String
    public var fontSize: Double
    /// True when lines wrap at the width limit; false when each of the text's lines draws whole.
    public var wraps: Bool
    /// True when the text did not fit even at the smallest size, so its end is cut.
    public var isCut: Bool
    /// The text's box inside the backing, from the backing's top left.
    public var textFrame: CGRect
    /// The backing, in screen coordinates, centered on the screen.
    public var frame: CGRect

    /// Lays out `text` on a screen whose visible frame is `screen`, in `font`'s weight and design.
    @MainActor public static func make(
        _ text: String, screen: CGRect, font: ThemeFont, metrics: LargeTypeMetrics = .standard
    ) -> LargeTypeLayout {
        let shown = cut(text, to: metrics.maximumCharacters)
        let maxWidth = screen.width * metrics.widthFraction
        let maxHeight = screen.height * metrics.heightFraction
        let minimum = metrics.minimumSize
        let cap = max(minimum, screen.height * metrics.maximumSizeFraction)

        // Width and height both scale with the size, so one measure at a reference size gives the
        // size at which each line fits whole.
        let reference = 100.0
        let natural = measure(shown, font: font, size: reference, width: nil)
        var unwrapped = min(
            cap, reference * maxWidth / max(natural.width, 1), reference * maxHeight / max(natural.height, 1))
        for _ in 0..<3 {
            let size = measure(shown, font: font, size: unwrapped, width: nil)
            guard size.width > maxWidth || size.height > maxHeight else { break }
            unwrapped *= min(maxWidth / max(size.width, 1), maxHeight / max(size.height, 1)) * 0.995
        }

        var fontSize: Double
        var wraps = false
        var isCut = false
        if unwrapped >= max(minimum, screen.height * metrics.unwrappedFraction) {
            fontSize = unwrapped.rounded(.down)
        } else {
            wraps = true
            // A word never breaks while the longest one fits the width.
            let word = longestWordWidth(shown, font: font, size: reference)
            let upper = max(minimum, min(cap, reference * maxWidth / max(word, 1)))
            func fits(_ size: Double) -> Bool {
                measure(shown, font: font, size: size, width: maxWidth).height <= maxHeight
            }
            if fits(upper) {
                fontSize = upper
            } else if !fits(minimum) {
                fontSize = minimum
                isCut = true
            } else {
                var low = minimum
                var high = upper
                while high - low > 0.5 {
                    let middle = (low + high) / 2
                    if fits(middle) { low = middle } else { high = middle }
                }
                fontSize = low
            }
            fontSize = fontSize.rounded(.down)
        }

        let measured = measure(shown, font: font, size: fontSize, width: wraps ? maxWidth : nil)
        let textSize = CGSize(
            width: ceil(min(measured.width, maxWidth)), height: ceil(min(measured.height, maxHeight)))
        let padding = min(metrics.maximumPadding, max(metrics.minimumPadding, fontSize * metrics.paddingFraction))
        let size = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        let origin = CGPoint(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded())
        return LargeTypeLayout(
            text: shown, fontSize: fontSize, wraps: wraps, isCut: isCut,
            textFrame: CGRect(origin: CGPoint(x: padding, y: padding), size: textSize),
            frame: CGRect(origin: origin, size: size))
    }

    /// The text as Large Type draws it: centered lines in `font` at `size`, white unless `color`
    /// says otherwise. Lines wrap at word boundaries when a width is given.
    @MainActor public static func attributed(
        _ text: String, font: ThemeFont, size: Double, color: NSColor = .white
    ) -> NSAttributedString {
        var sized = font
        sized.size = size
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text, attributes: [.font: sized.nsFont, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// The options that measure and draw the text the same way.
    public static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// The size the text takes at `size`: wrapped at `width`, or on its own lines without one.
    @MainActor static func measure(_ text: String, font: ThemeFont, size: Double, width: Double?) -> CGSize {
        let bounds = CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let rect = attributed(text, font: font, size: size).boundingRect(with: bounds, options: drawingOptions)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// The width of the widest word at `size`.
    @MainActor static func longestWordWidth(_ text: String, font: ThemeFont, size: Double) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return words.map { measure(String($0), font: font, size: size, width: nil).width }.max() ?? 0
    }

    /// The text, cut to `limit` characters with an ellipsis, with spaces and line breaks around it
    /// left out.
    static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
