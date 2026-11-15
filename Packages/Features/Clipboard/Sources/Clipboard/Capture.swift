import CryptoKit
import Foundation
import Kit
import KitStorage

/// An item's identity: a hash of what it holds. Copying the same thing again gives the same key, so
/// the history keeps one item and moves it to the top. Row IDs use it, so it stays the same across
/// launches and when the item moves.
nonisolated struct ItemKey: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    /// Reads the 16-digit hex form.
    init?(hex: String) {
        guard hex.count == 16, let value = UInt64(hex, radix: 16) else { return nil }
        self.value = value
    }

    /// The first 8 bytes of a SHA-256 digest of the bytes.
    init(hashing data: some DataProtocol) {
        var value: UInt64 = 0
        for byte in SHA256.hash(data: data).prefix(8) {
            value = value << 8 | UInt64(byte)
        }
        self.value = value
    }

    /// 16 hex digits, padded.
    var hex: String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    var description: String { hex }

    /// The key as SQLite stores it, a signed 64-bit integer with the same bits.
    var sqlite: SQLiteValue { .integer(Int64(bitPattern: value)) }

    init(sqlite: Int64) {
        value = UInt64(bitPattern: sqlite)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = ItemKey(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an item key")
        }
        self = key
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The part of one pasteboard change that clipboard history keeps, classified by kind.
///
/// It is made only from an entry the pasteboard service handed over, which has already dropped
/// concealed, transient and auto-generated content.
nonisolated struct Capture: Hashable, Sendable {
    var kind: ClipKind
    /// The text, the link, the color as typed, or the file paths one per line. Nil for images.
    var text: String?
    /// The styled form of rich text.
    var rtf: Data?
    /// Image bytes and their uniform type identifier.
    var image: Data?
    var imageType: String?
    /// The bundle ID of the app that copied it.
    var source: String?

    /// Picks what to keep from a pasteboard change. Nil when there is nothing worth keeping, or when
    /// the content is larger than `maximumBytes`.
    ///
    /// Files win, then rich text, then an image, then a link, then plain text. Rich text wins over
    /// an image because office apps put a picture of the selection beside the text. Rich text whose
    /// plain form is a lone link or color is kept as that link or color.
    init?(_ entry: PasteboardEntry, maximumBytes: Int) {
        source = entry.sourceBundleID
        var files: [URL]?
        var richText: (rtf: Data, plain: String)?
        var image: (data: Data, type: String)?
        var link: URL?
        var plain: String?
        for content in entry.contents {
            switch content {
            case .files(let urls): files = files ?? urls.filter(\.isFileURL)
            case .richText(let rtf, let text): richText = richText ?? (rtf, text)
            case .image(let data, let type): image = image ?? (data, type)
            case .url(let url): link = link ?? url
            case .text(let text): plain = plain ?? text
            }
        }
        if let files, !files.isEmpty {
            kind = .files
            text = files.map(\.path).joined(separator: "\n")
        } else if let richText, Self.hasContent(richText.plain) {
            let plainKind = Self.kind(ofPlainText: richText.plain)
            if plainKind == .text {
                kind = .richText
                text = richText.plain
                // Styling over the size cap is dropped; the text is still worth keeping.
                rtf = richText.rtf.count <= maximumBytes ? richText.rtf : nil
                if rtf == nil { kind = .text }
            } else {
                kind = plainKind
                text = richText.plain.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let image {
            guard !image.data.isEmpty, image.data.count <= maximumBytes else { return nil }
            kind = .image
            self.image = image.data
            imageType = image.type
        } else if let link, link.isFileURL {
            kind = .files
            text = link.path
        } else if let link, link.scheme != nil {
            kind = .link
            text = link.absoluteString
        } else if let plain, Self.hasContent(plain) {
            kind = Self.kind(ofPlainText: plain)
            text = kind == .text ? plain : plain.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        if let text, text.utf8.count > maximumBytes { return nil }
    }

    /// The item's identity. Text, links and colors with the same text are one item, so a copy of
    /// the same words from a styled and a plain source moves one item to the top.
    var key: ItemKey {
        if let image { return ItemKey(hashing: Data("image\u{0}".utf8) + image) }
        let prefix = kind == .files ? "files\u{0}" : "text\u{0}"
        return ItemKey(hashing: Data((prefix + (text ?? "")).utf8))
    }

    /// The size the history shows: the text's UTF-8 bytes or the image's bytes.
    var byteCount: Int {
        image?.count ?? text?.utf8.count ?? 0
    }

    /// True when the text holds more than white space.
    private static func hasContent(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Plain text that is a lone web link or a lone hex color is kept as that kind.
    static func kind(ofPlainText text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return .text }
        if isHexColor(trimmed) { return .color }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host(), !host.isEmpty
        {
            return .link
        }
        return .text
    }

    /// `#RRGGBB` or `#RRGGBBAA`, or `#RGB` and `#RGBA` with at least one letter, so an issue number
    /// such as `#123` stays text.
    static func isHexColor(_ text: String) -> Bool {
        guard text.hasPrefix("#") else { return false }
        let digits = text.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return false }
        switch digits.count {
        case 6, 8: return true
        case 3, 4: return digits.contains(where: \.isLetter)
        default: return false
        }
    }
}
