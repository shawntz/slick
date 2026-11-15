import CoreGraphics

/// The main content of a detail pane.
nonisolated public enum DetailBody: Sendable, Equatable {
    /// Plain text in the body font. ANSI colour codes draw as colour within the theme's
    /// contrast rule; other escape sequences are dropped.
    case text(String)
    /// Plain text in the monospaced font, such as code or command output. ANSI colour codes draw
    /// as colour, as in `text`.
    case monospaced(String)
    /// Styled text with fonts, sizes and colours, kept within the theme's rules.
    case richText(RichText)
    /// Markdown: headings, emphasis, code spans, code blocks, lists, quotes and links.
    case markdown(String)
    /// An image, aspect-fitted. Nil shows nothing until `DetailPane.setImage(_:)` fills it.
    case image(CGImage?)
    /// A large swatch of a colour, with an optional caption such as its hex value.
    case color(ThemeColor, caption: String?)
    /// A file: its thumbnail slot and its name. The thumbnail arrives later through
    /// `DetailPane.setImage(_:)`, because making one reads the disk.
    case file(name: String, thumbnail: CGImage?)

    public static func == (lhs: DetailBody, rhs: DetailBody) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)), (.monospaced(let a), .monospaced(let b)),
            (.markdown(let a), .markdown(let b)):
            a == b
        case (.richText(let a), .richText(let b)): a == b
        case (.image(let a), .image(let b)): a === b
        case (.color(let a, let captionA), .color(let b, let captionB)): a == b && captionA == captionB
        case (.file(let a, let thumbA), .file(let b, let thumbB)): a == b && thumbA === thumbB
        default: false
        }
    }

    /// The text of a text, monospaced, Markdown or rich text body.
    var text: String? {
        switch self {
        case .text(let text), .monospaced(let text), .markdown(let text): text
        case .richText(let rich): rich.plainText
        default: nil
        }
    }

    /// Whether two bodies are the same kind of text, so one can extend the other.
    func isSameTextKind(as other: DetailBody) -> Bool {
        switch (self, other) {
        case (.text, .text), (.monospaced, .monospaced), (.markdown, .markdown): true
        default: false
        }
    }
}

/// A coloured tag in the metadata table.
nonisolated public struct MetadataTag: Sendable, Equatable {
    public var text: String
    public var color: ThemeColor

    public init(_ text: String, color: ThemeColor) {
        self.text = text
        self.color = color
    }
}

/// One row of the metadata table under the detail body.
nonisolated public enum MetadataItem: Sendable, Equatable {
    /// A label and a value.
    case label(String, value: String)
    /// A label and a value with a small icon before the value, such as an app's icon beside its
    /// name. A symbol is tinted with the value's colour.
    case iconLabel(String, value: String, icon: CardIcon)
    /// A label and link text, drawn in the link colour. Clicking it calls `DetailPane.onOpenLink`.
    case link(String, text: String, url: String)
    /// A label and coloured tags.
    case tags(String, [MetadataTag])
    /// A label, a small swatch and its text.
    case color(String, ThemeColor, text: String)
    /// A hairline between groups.
    case separator
}

/// Everything a detail pane shows.
nonisolated public struct DetailContent: Sendable, Equatable {
    public var body: DetailBody?
    public var metadata: [MetadataItem]

    public init(body: DetailBody? = nil, metadata: [MetadataItem] = []) {
        self.body = body
        self.metadata = metadata
    }

    public static let empty = DetailContent()

    public var isEmpty: Bool { body == nil && metadata.isEmpty }
}
