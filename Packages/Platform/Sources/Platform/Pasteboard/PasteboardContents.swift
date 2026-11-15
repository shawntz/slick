import AppKit
import Foundation
import Kit

/// Turns Kit's pasteboard contents into pasteboard items and back. Pure apart from the pasteboard
/// it is handed, which must be touched on one thread at a time.
nonisolated enum PasteboardContents {
    /// Image types read from the pasteboard, preferred first.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
    ]

    /// The items that hold `content`, each carrying `markers`: marker type names with their
    /// values, empty for flags.
    static func items(for content: PasteboardContent, markers: [(type: String, value: String)]) -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []
        switch content {
        case .text(let text):
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            items.append(item)
        case .richText(let rtf, let plain):
            let item = NSPasteboardItem()
            item.setData(rtf, forType: .rtf)
            item.setString(plain, forType: .string)
            items.append(item)
        case .url(let url):
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
            items.append(item)
        case .files(let urls):
            for url in urls {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                items.append(item)
            }
        case .image(let data, let typeIdentifier):
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
            items.append(item)
        }
        for item in items {
            for marker in markers {
                item.setString(marker.value, forType: NSPasteboard.PasteboardType(marker.type))
            }
        }
        return items
    }

    /// What the pasteboard holds, richest first: files alone, or an image, styled text, a URL and
    /// plain text, as far as each is there. Large or unused representations, such as web archives,
    /// are never read. An image over `maximumImageBytes` is left out.
    static func read(from board: NSPasteboard, maximumImageBytes: Int) -> [PasteboardContent] {
        let types = Set(board.types ?? [])
        if types.contains(.fileURL),
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL],
            !urls.isEmpty
        {
            return [.files(urls)]
        }
        var contents: [PasteboardContent] = []
        if let type = imageTypes.first(where: types.contains), let data = board.data(forType: type),
            data.count <= maximumImageBytes
        {
            contents.append(.image(data, typeIdentifier: type.rawValue))
        }
        let plain = types.contains(.string) ? board.string(forType: .string) : nil
        if types.contains(.rtf), let rtf = board.data(forType: .rtf), let plain {
            contents.append(.richText(rtf: rtf, plain: plain))
        }
        if types.contains(.URL), let text = board.string(forType: .URL), let url = URL(string: text), url.scheme != nil
        {
            contents.append(.url(url))
        }
        if let plain, !plain.isEmpty {
            contents.append(.text(plain))
        }
        return contents
    }
}
