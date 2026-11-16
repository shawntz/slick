import Foundation

/// What the detail pane or a detail page shows: a body and a list of metadata.
public struct Detail: Hashable, Sendable {
    /// The main content. Nil shows only the metadata.
    public var body: DetailBody?
    /// Label and value pairs under or beside the body.
    public var metadata: [MetadataItem]
    /// What a detail page stands for, as ``Row/represents`` does for a row: the host then offers
    /// every feature's universal actions for it, and Show in Large Type for text. Nil for none.
    /// A detail in the pane beside a list needs none: its row's `represents` counts.
    public var represents: Selection?

    public init(_ body: DetailBody? = nil, metadata: [MetadataItem] = [], represents: Selection? = nil) {
        self.body = body
        self.metadata = metadata
        self.represents = represents
    }

    /// A detail showing Markdown.
    public static func markdown(_ text: String, metadata: [MetadataItem] = []) -> Detail {
        Detail(.markdown(text), metadata: metadata)
    }

    /// Applies one streamed update. The host and `FeatureHarness` both use this, so a stream means
    /// the same thing on screen and in tests.
    public mutating func apply(_ update: DetailUpdate) {
        switch update {
        case .replace(let detail):
            self = detail
        case .append(let text):
            switch body {
            case .markdown(let existing): body = .markdown(existing + text)
            case .text(let existing, let monospaced): body = .text(existing + text, monospaced: monospaced)
            default: body = .markdown(text)
            }
        case .metadata(let items):
            metadata = items
        }
    }
}

/// The main content of a detail.
public enum DetailBody: Hashable, Sendable {
    /// Markdown: headings, emphasis, lists, links, code blocks and tables.
    case markdown(String)
    /// Plain text, optionally in a monospaced font. ANSI color codes are drawn as color.
    case text(String, monospaced: Bool = false)
    /// Styled text in RTF, with its plain-text form for when the RTF cannot be drawn.
    case richText(rtf: Data, plain: String)
    /// An image from a file or from memory, scaled to fit.
    case image(ImageSource)
    /// A Quick Look preview of a local file, drawn inside the panel.
    case preview(URL)
    /// A large swatch of a color.
    case color(KitColor)
    /// A link, with the page's title and image when the host has them cached.
    case link(URL)
}

/// Where an image comes from.
public enum ImageSource: Hashable, Sendable {
    /// A local image file.
    case file(URL)
    /// Encoded image data, such as PNG or TIFF bytes.
    case data(Data)
}

/// One entry in a detail's metadata list.
public enum MetadataItem: Hashable, Sendable {
    /// A label and a value, with an optional icon before the value.
    case label(String, value: String, icon: Icon? = nil)
    /// A label and a link the user can open.
    case link(String, text: String, url: URL)
    /// A label and colored tags.
    case tags(String, [Tag])
    /// A label and a color swatch.
    case color(String, KitColor)
    /// A label and a date the host formats for the user's locale.
    case date(String, Date)
    /// A thin rule between groups.
    case separator
}

/// A colored tag in metadata.
public struct Tag: Hashable, Sendable {
    public var text: String
    public var color: KitColor?

    public init(_ text: String, color: KitColor? = nil) {
        self.text = text
        self.color = color
    }
}

/// One change to a streamed detail. See ``DetailSource``.
public enum DetailUpdate: Hashable, Sendable {
    /// Replaces the whole detail.
    case replace(Detail)
    /// Appends text to a Markdown or plain-text body, such as the next tokens of an answer or the next
    /// lines of a script's output.
    case append(String)
    /// Replaces the metadata and keeps the body.
    case metadata([MetadataItem])
}
