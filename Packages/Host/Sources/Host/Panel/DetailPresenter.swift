import AppKit
import ImageIO
import Kit
import LauncherUI
import QuickLookThumbnailing

/// Draws Kit details in one LauncherUI ``DetailPane``: the list's pane or a detail page.
///
/// Mapping is synchronous. Anything that reads a file or decodes runs off the main thread after
/// the text and metadata are drawn: images, Quick Look thumbnails for previews, and rich text,
/// which shows its plain form until its runs are converted. A newer detail cancels those loads.
@MainActor final class DetailPresenter {
    let pane: DetailPane
    /// What the pane shows now, as Kit sees it.
    private(set) var detail: Detail?
    private var generation = 0
    private var resourceTask: Task<Void, Never>?

    init(pane: DetailPane) {
        self.pane = pane
    }

    /// Shows a detail, or clears the pane for nil.
    func show(_ detail: Detail?) {
        generation += 1
        resourceTask?.cancel()
        resourceTask = nil
        self.detail = detail
        guard let detail else {
            pane.apply(.empty)
            return
        }
        let content = Self.content(detail)
        pane.apply(content)
        guard let load = Self.resource(for: detail.body) else { return }
        let current = generation
        resourceTask = Task { [weak self] in
            let loaded = await load()
            guard let self, current == generation, !Task.isCancelled else { return }
            switch loaded {
            case .image(let image): pane.setImage(image)
            case .markdown(let markdown):
                pane.apply(DetailContent(body: .markdown(markdown), metadata: content.metadata))
            case .none: break
            }
        }
    }

    /// Appends streamed text to a text body that is already showing.
    func append(_ text: String, plainText: Bool) {
        pane.append(plainText ? Self.strippingTerminalCodes(text) : text)
    }

    /// Cancels any resource still loading.
    func cancel() {
        generation += 1
        resourceTask?.cancel()
        resourceTask = nil
    }

    // MARK: Mapping

    /// A Kit detail as LauncherUI draws it. Image bodies start empty and fill in when loaded.
    nonisolated static func content(_ detail: Detail) -> DetailContent {
        DetailContent(body: detail.body.map(body), metadata: detail.metadata.map(metadata))
    }

    nonisolated static func body(_ body: Kit.DetailBody) -> LauncherUI.DetailBody {
        switch body {
        case .markdown(let text): .markdown(text)
        case .text(let text, let monospaced):
            monospaced ? .monospaced(strippingTerminalCodes(text)) : .text(strippingTerminalCodes(text))
        case .richText(_, let plain): .text(plain)
        case .image: .image(nil)
        case .preview(let url): .file(name: url.lastPathComponent, thumbnail: nil)
        case .color(let color): .color(RowMapper.themeColor(color), caption: hex(color))
        case .link(let url): .markdown("[\(escapedMarkdown(url.absoluteString))](\(url.absoluteString))")
        }
    }

    nonisolated static func metadata(_ item: Kit.MetadataItem) -> LauncherUI.MetadataItem {
        switch item {
        case .label(let label, let value, _): .label(label, value: value)
        case .link(let label, let text, let url): .link(label, text: text, url: url.absoluteString)
        case .tags(let label, let tags):
            .tags(label, tags.map { MetadataTag($0.text, color: RowMapper.themeColor($0.color ?? .secondary)) })
        case .color(let label, let color): .color(label, RowMapper.themeColor(color), text: hex(color) ?? "")
        case .date(let label, let date): .label(label, value: date.formatted(date: .abbreviated, time: .shortened))
        case .separator: .separator
        }
    }

    /// `#RRGGBB` for an RGB colour, the name for a semantic one.
    nonisolated static func hex(_ color: KitColor) -> String? {
        switch color {
        case .rgba(let red, let green, let blue, _):
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        case .semantic(let semantic):
            return semantic.rawValue.capitalized
        }
    }

    /// Removes ANSI escape sequences such as colour codes, which the pane cannot draw as colour
    /// yet, so a script's output does not show them as text.
    nonisolated static func strippingTerminalCodes(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{1B}") else { return text }
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                result.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            while let code = iterator.next() {
                if (0x40...0x7E).contains(code.value) { break }
            }
        }
        return String(result)
    }

    /// Escapes the characters Markdown would read as markup.
    nonisolated static func escapedMarkdown(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]#<>".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: Resources

    enum Loaded: Sendable {
        case image(CGImage?)
        case markdown(String)
        case none
    }

    /// The off-main load a body needs, or nil.
    private static func resource(for body: Kit.DetailBody?) -> (@Sendable () async -> Loaded)? {
        switch body {
        case .image(let source): { .image(await loadImage(source)) }
        case .preview(let url): { .image(await thumbnail(url)) }
        case .richText(let rtf, _): { (await markdown(fromRTF: rtf)).map(Loaded.markdown) ?? Loaded.none }
        default: nil
        }
    }

    @concurrent nonisolated static func loadImage(_ source: ImageSource) async -> CGImage? {
        let imageSource: CGImageSource? =
            switch source {
            case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
            case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
            }
        guard let imageSource else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }

    @concurrent nonisolated static func thumbnail(_ url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 256, height: 256), scale: 2, representationTypes: .thumbnail)
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }

    /// Rich text as Markdown: bold, italic, monospaced runs and links keep their meaning; fonts,
    /// sizes and colours follow the theme, so the text keeps its contrast on the glass.
    @concurrent nonisolated static func markdown(fromRTF data: Data) async -> String? {
        guard
            let text = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return nil }
        let string = text.string as NSString
        var markdown = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let run = string.substring(with: range)
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let link: String? =
                (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            // Markup cannot span a line break: style each line of the run on its own.
            let lines = run.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 { markdown += "\n" }
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    markdown += line
                    continue
                }
                var piece = traits.contains(.monoSpace) ? "`\(line)`" : escapedMarkdown(line)
                if !traits.contains(.monoSpace) {
                    if traits.contains(.bold) { piece = "**\(piece)**" }
                    if traits.contains(.italic) { piece = "*\(piece)*" }
                }
                if let link { piece = "[\(piece)](\(link))" }
                markdown += piece
            }
        }
        return markdown
    }
}

/// Kit details as LauncherUI's detail pane draws them, for tests and other hosts of the pane.
public enum DetailMapping {
    /// The pane's content for a detail. Image bodies start empty and fill in once loaded.
    public static func content(_ detail: Detail) -> DetailContent {
        DetailPresenter.content(detail)
    }
}
