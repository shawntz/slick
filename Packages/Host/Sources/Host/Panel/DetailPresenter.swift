import AppKit
import ImageIO
import Kit
import LauncherUI
import QuickLookThumbnailing

/// Draws Kit details in one LauncherUI ``DetailPane``: the list's pane or a detail page.
///
/// Mapping is synchronous. Anything that reads a file or decodes runs off the main thread after
/// the text and metadata are drawn: images, Quick Look thumbnails for previews, and rich text,
/// which shows its plain form until its runs are read. A newer detail cancels those loads. Text
/// keeps its ANSI colours, which the pane draws within the theme's contrast rule. A metadata label
/// with an icon draws the icon before its value, from the ``IconProvider`` when the page set
/// ``rowMapper``; an icon that is not ready yet draws when the provider signals.
@MainActor final class DetailPresenter {
    let pane: DetailPane
    /// Looks up metadata icons. Without it only SF Symbols draw.
    var rowMapper: RowMapper?
    /// What the pane shows now, as Kit sees it.
    private(set) var detail: Detail?
    private var generation = 0
    private var resourceTask: Task<Void, Never>?
    /// The body that replaced the detail's own once loaded, such as rich text read from RTF.
    private var loadedBody: LauncherUI.DetailBody?
    /// Metadata icons that were not ready when the detail drew.
    private var missingIcons = false

    init(pane: DetailPane) {
        self.pane = pane
    }

    /// Shows a detail, or clears the pane for nil.
    func show(_ detail: Detail?) {
        generation += 1
        resourceTask?.cancel()
        resourceTask = nil
        loadedBody = nil
        self.detail = detail
        guard let detail else {
            missingIcons = false
            pane.apply(.empty)
            return
        }
        let content = Self.content(detail, icons: metadataIcons(detail))
        pane.apply(content)
        guard let load = Self.resource(for: detail.body) else { return }
        let current = generation
        resourceTask = Task { [weak self] in
            let loaded = await load()
            guard let self, current == generation, !Task.isCancelled else { return }
            switch loaded {
            case .image(let image): pane.setImage(image)
            case .richText(let rich):
                loadedBody = .richText(rich)
                pane.apply(DetailContent(body: .richText(rich), metadata: content.metadata))
            case .none: break
            }
        }
    }

    /// Appends streamed text to a text body that is already showing. ANSI codes stay: the pane
    /// draws them as colour and keeps a code cut between two appends.
    func append(_ text: String, plainText: Bool) {
        pane.append(text)
    }

    /// Icons may be ready now: draws the metadata again when one was missing.
    func iconsDidChange() {
        guard missingIcons, let detail else { return }
        var content = Self.content(detail, icons: metadataIcons(detail))
        if let loadedBody { content.body = loadedBody }
        pane.apply(content)
    }

    /// The card icons of the detail's metadata labels that can draw now, by Kit icon.
    private func metadataIcons(_ detail: Detail) -> [Icon: CardIcon] {
        var icons: [Icon: CardIcon] = [:]
        missingIcons = false
        for item in detail.metadata {
            guard case .label(_, _, let icon?) = item, icons[icon] == nil else { continue }
            if let card = rowMapper?.cardIcon(icon) ?? Self.symbolIcon(icon) {
                icons[icon] = card
            } else {
                missingIcons = true
            }
        }
        return icons
    }

    nonisolated static func symbolIcon(_ icon: Icon) -> CardIcon? {
        if case .symbol(let name, _) = icon { return .symbol(name) }
        return nil
    }

    /// Cancels any resource still loading.
    func cancel() {
        generation += 1
        resourceTask?.cancel()
        resourceTask = nil
    }

    // MARK: Mapping

    /// A Kit detail as LauncherUI draws it. Image bodies start empty and fill in when loaded.
    /// `icons` draws metadata icons; a label whose icon is missing from it draws without one, except
    /// an SF Symbol, which needs no lookup.
    nonisolated static func content(_ detail: Detail, icons: [Icon: CardIcon] = [:]) -> DetailContent {
        DetailContent(body: detail.body.map(body), metadata: detail.metadata.map { metadata($0, icons: icons) })
    }

    nonisolated static func body(_ body: Kit.DetailBody) -> LauncherUI.DetailBody {
        switch body {
        case .markdown(let text): .markdown(text)
        case .text(let text, let monospaced): monospaced ? .monospaced(text) : .text(text)
        case .richText(_, let plain): .text(plain)
        case .image: .image(nil)
        case .preview(let url): .file(name: url.lastPathComponent, thumbnail: nil)
        case .color(let color): .color(RowMapper.themeColor(color), caption: hex(color))
        case .link(let url): .markdown("[\(escapedMarkdown(url.absoluteString))](\(url.absoluteString))")
        }
    }

    nonisolated static func metadata(_ item: Kit.MetadataItem, icons: [Icon: CardIcon] = [:]) -> LauncherUI.MetadataItem
    {
        switch item {
        case .label(let label, let value, let icon):
            if let card = icon.flatMap({ icons[$0] ?? symbolIcon($0) }) {
                .iconLabel(label, value: value, icon: card)
            } else {
                .label(label, value: value)
            }
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
        case richText(RichText)
        case none
    }

    /// The off-main load a body needs, or nil.
    private static func resource(for body: Kit.DetailBody?) -> (@Sendable () async -> Loaded)? {
        switch body {
        case .image(let source): { .image(await loadImage(source)) }
        case .preview(let url): { .image(await thumbnail(url)) }
        case .richText(let rtf, _): { (await richText(fromRTF: rtf)).map(Loaded.richText) ?? Loaded.none }
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

    /// Rich text read from RTF: its runs with their fonts, relative sizes, traits, colours and
    /// links. The pane keeps sizes and colours within the theme's rules. Sizes are taken relative to
    /// the size most of the text uses.
    @concurrent nonisolated static func richText(fromRTF data: Data) async -> RichText? {
        guard
            let text = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return nil }
        var characters: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            characters[font.pointSize, default: 0] += range.length
        }
        let bodySize = characters.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12
        return RichText(text, bodySize: Double(bodySize))
    }
}

/// Kit details as LauncherUI's detail pane draws them, for tests and other hosts of the pane.
public enum DetailMapping {
    /// The pane's content for a detail. Image bodies start empty and fill in once loaded.
    public static func content(_ detail: Detail) -> DetailContent {
        DetailPresenter.content(detail)
    }
}
