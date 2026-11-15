import Foundation
import Kit

/// The detail pane for one item: a preview that suits its kind, then its type, source app, size and
/// times. Built off the main thread: counting the words of a large text is not free.
nonisolated enum HistoryDetail {
    /// Longer text is cut in the preview. The item itself stays whole.
    static let previewCharacters = 20_000
    /// Styled text larger than this shows as plain text.
    static let richPreviewBytes = 1 << 20

    @concurrent static func make(_ item: ItemDetail, appName: String?, locale: Locale) async -> Detail {
        let summary = item.summary
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        var tags = [Tag(Strings.Kinds.title(for: summary.kind), color: .accent)]
        if summary.isPinned { tags.append(Tag(Strings.Detail.pinned, color: .orange)) }
        var metadata: [MetadataItem] = [.tags(Strings.Detail.type, tags)]
        if let source = summary.source {
            metadata.append(.label(Strings.Detail.application, value: appName ?? source, icon: .app(bundleID: source)))
        }
        let body: DetailBody?
        switch summary.kind {
        case .text, .richText:
            let text = item.text ?? ""
            if summary.kind == .richText, let rtf = item.rtf, rtf.count <= richPreviewBytes {
                body = .richText(rtf: rtf, plain: text)
            } else {
                body = .text(preview(of: text), monospaced: false)
            }
            metadata += [
                .label(Strings.Detail.characters, value: text.count.formatted(number)),
                .label(Strings.Detail.words, value: wordCount(text).formatted(number)),
            ]
        case .link:
            let url = item.text.flatMap { URL(string: $0) }
            body = url.map(DetailBody.link) ?? .text(item.text ?? "", monospaced: false)
            if let url {
                metadata.append(.link(Strings.Detail.link, text: url.host() ?? url.absoluteString, url: url))
            }
        case .color:
            let color = item.text.flatMap { KitColor(hex: $0) }
            body = color.map(DetailBody.color) ?? .text(item.text ?? "", monospaced: true)
            if let color { metadata.append(.color(Strings.Detail.color, color)) }
        case .image:
            body = summary.imageURL.map { .image(.file($0)) }
            if let width = summary.pixelWidth, let height = summary.pixelHeight {
                metadata.append(
                    .label(Strings.Detail.dimensions, value: Strings.Detail.dimensions(width: width, height: height)))
            }
        case .files:
            let files = HistoryStore.fileURLs(item.text ?? "")
            body = files.count == 1 ? .preview(files[0]) : .text(files.map(\.path).joined(separator: "\n"))
            metadata.append(.label(Strings.Detail.items, value: files.count.formatted(number)))
        }
        let bytes = ByteCountFormatStyle(style: .file, locale: locale).format(Int64(summary.byteCount))
        metadata += [
            .label(Strings.Detail.size, value: bytes), .separator, .date(Strings.Detail.copied, summary.copied),
        ]
        if item.copyCount > 1 {
            metadata += [
                .date(Strings.Detail.firstCopied, item.firstCopied),
                .label(Strings.Detail.timesCopied, value: item.copyCount.formatted(number)),
            ]
        }
        return Detail(body, metadata: metadata)
    }

    /// The text as the pane shows it: cut after ``previewCharacters`` with a note that says so.
    static func preview(of text: String) -> String {
        guard text.count > previewCharacters else { return text }
        return String(text.prefix(previewCharacters)) + Strings.Detail.cutNotice(shown: previewCharacters)
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
