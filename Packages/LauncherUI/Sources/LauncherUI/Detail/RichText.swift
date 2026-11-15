import AppKit

/// Styled text for the detail pane, such as a note or an email read from RTF: runs with a font, a
/// relative size, traits and a colour. The pane draws it within the theme's rules: sizes stay
/// between `minimumScale` and `maximumScale` of the body size, and every colour is moved toward
/// the text colour until it reaches 4.5:1 over the glass.
nonisolated public struct RichText: Sendable, Equatable {
    /// One stretch of text with one style. Paragraphs are separated by line breaks in the text.
    public struct Run: Sendable, Equatable {
        public var text: String
        /// A font family such as "Georgia". Nil, or a family the Mac lacks, uses the body font.
        public var fontFamily: String?
        /// The size relative to the body text: 1 is the body size, 1.5 half again as large.
        public var sizeScale: Double
        public var isBold: Bool
        public var isItalic: Bool
        public var isMonospaced: Bool
        public var isUnderlined: Bool
        public var isStruckThrough: Bool
        /// The text colour the source asked for. Nil uses the body colour.
        public var color: ThemeColor?
        /// A link target. Clicking the run calls `DetailPane.onOpenLink`.
        public var link: String?

        public init(
            _ text: String, fontFamily: String? = nil, sizeScale: Double = 1, isBold: Bool = false,
            isItalic: Bool = false, isMonospaced: Bool = false, isUnderlined: Bool = false,
            isStruckThrough: Bool = false, color: ThemeColor? = nil, link: String? = nil
        ) {
            self.text = text
            self.fontFamily = fontFamily
            self.sizeScale = sizeScale
            self.isBold = isBold
            self.isItalic = isItalic
            self.isMonospaced = isMonospaced
            self.isUnderlined = isUnderlined
            self.isStruckThrough = isStruckThrough
            self.color = color
            self.link = link
        }
    }

    public var runs: [Run]

    /// The smallest and largest size a run may take, relative to the body text.
    public static let minimumScale = 0.85
    public static let maximumScale = 2.0

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// The text without styles.
    public var plainText: String { runs.map(\.text).joined() }

    /// The runs of an attributed string, such as one read from RTF off the main thread. Sizes are
    /// taken relative to `bodySize`, the size the source's plain text uses.
    public init(_ attributed: NSAttributedString, bodySize: Double = 12) {
        var runs: [Run] = []
        let whole = NSRange(location: 0, length: attributed.length)
        let text = attributed.string as NSString
        attributed.enumerateAttributes(in: whole) { attributes, range, _ in
            var run = Run(text.substring(with: range))
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                run.isBold = traits.contains(.bold)
                run.isItalic = traits.contains(.italic)
                run.isMonospaced = traits.contains(.monoSpace)
                run.sizeScale = bodySize > 0 ? Double(font.pointSize) / bodySize : 1
                run.fontFamily = run.isMonospaced ? nil : font.familyName
            }
            if let color = attributes[.foregroundColor] as? NSColor,
                let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0
            {
                run.color = ThemeColor(
                    red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                    blue: Double(rgb.blueComponent))
            }
            if let style = attributes[.underlineStyle] as? Int, style != 0 { run.isUnderlined = true }
            if let style = attributes[.strikethroughStyle] as? Int, style != 0 { run.isStruckThrough = true }
            if let url = attributes[.link] as? URL {
                run.link = url.absoluteString
            } else if let link = attributes[.link] as? String {
                run.link = link
            }
            if let last = runs.last, last.isSameStyle(as: run) {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
        self.runs = runs
    }
}

extension RichText.Run {
    nonisolated func isSameStyle(as other: RichText.Run) -> Bool {
        var copy = other
        copy.text = text
        return copy == self
    }
}
