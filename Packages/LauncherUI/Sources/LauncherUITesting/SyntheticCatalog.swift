import AppKit
import LauncherUI

/// Made-up launcher items with generated icons, for captures, benchmarks and tests. Every name is
/// invented; nothing is read from the machine.
public final class SyntheticCatalog {
    /// One item before it is matched.
    public struct Item {
        public let id: UInt64
        public let title: String
        public let subtitle: String
        public let accessories: [RowAccessory]
        public let icon: CGImage?
    }

    public let items: [Item]

    private static let names = [
        "Aurora Notes", "Basil Mail", "Cobalt Terminal", "Drift Browser", "Ember Photos", "Fable Music",
        "Granite Calendar", "Harbor Maps", "Indigo Editor", "Juniper Tasks", "Kestrel Weather", "Lumen Preview",
        "Meridian Clock", "Nimbus Files", "Orchid Contacts", "Pebble Calculator", "Quill Writer", "Rook Chess",
        "Sable Podcasts", "Tidal Messages", "Umber Books", "Velvet Video", "Willow Reminders", "Yarrow Translate",
        "Zephyr Settings", "Clipboard History", "Search Snippets", "Window Left Half", "Window Right Half",
        "Toggle Dark Mode", "Convert Units", "Lock Screen", "Sleep Displays", "Quit All Apps", "Search Emoji",
        "Open Quicklink", "Create Snippet", "Kill Process", "Search Files", "System Activity", "Timer Five Minutes",
        "Focus Mode", "Screen Ruler", "Color Picker", "Paste as Plain Text", "Reset Launch Helper",
    ]
    private static let symbols = [
        "doc.text.fill", "envelope.fill", "terminal.fill", "globe", "photo.fill", "music.note", "calendar",
        "map.fill", "chevron.left.forwardslash.chevron.right", "checklist", "cloud.sun.fill", "eye.fill",
        "clock.fill", "folder.fill", "person.crop.circle.fill", "plus.forwardslash.minus", "pencil", "crown.fill",
        "mic.fill", "message.fill", "book.fill", "play.rectangle.fill", "bell.fill", "character.bubble.fill",
        "gearshape.fill",
    ]

    public init() {
        var items: [Item] = []
        for (index, title) in Self.names.enumerated() {
            let isApp = index < 25
            let subtitle =
                isApp ? "Application" : ["Command", "Window Management", "System", "Snippet", "Quicklink"][index % 5]
            var accessories: [RowAccessory] = []
            switch index % 6 {
            case 0: accessories = [.keycaps(["⌘", String(index % 9 + 1)])]
            case 1: accessories = [.text("3 days ago")]
            case 2: accessories = [.tag("Running", color: ThemeColor(.green))]
            case 3: accessories = [.tag("Pinned", color: ThemeColor(.blue)), .text("Yesterday")]
            case 4: accessories = [.text("Alias: \(title.prefix(2).lowercased())")]
            default: break
            }
            let symbol = Self.symbols[index % Self.symbols.count]
            let hue = Double((index * 37) % 100) / 100
            items.append(
                Item(
                    id: UInt64(index + 1), title: title, subtitle: subtitle, accessories: accessories,
                    icon: Self.icon(symbol: isApp ? symbol : "command", hue: hue, muted: !isApp)
                ))
        }
        self.items = items
    }

    /// The empty-query root: up to five Suggested rows, then Favorites.
    public func rootContent() -> ListContent {
        ListContent(sections: [
            ListSection(title: "Suggested", rows: items[0..<5].map { row($0, highlights: []) }),
            ListSection(
                title: "Favorites", rows: [items[25], items[29], items[9], items[13]].map { row($0, highlights: []) }),
        ])
    }

    /// Results for `query`: items whose title contains every query character in order, best
    /// first, with the matched characters highlighted.
    public func content(for query: String, limit: Int = 30, rowStyle: RowStyle = .oneLine) -> ListContent {
        let needle = Array(query.lowercased().utf16)
        var scored: [(score: Int, item: Item, ranges: [HighlightRange])] = []
        for item in items {
            guard let match = Self.match(needle, in: item.title) else { continue }
            scored.append((match.score, item, match.ranges))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.title < $1.item.title }
        let rows = scored.prefix(limit).map { row($0.item, highlights: $0.ranges) }
        return ListContent(
            sections: [ListSection(rows: Array(rows))], rowStyle: rowStyle, emphasizesMatches: !query.isEmpty)
    }

    /// Nine rows that differ from the nine of `step - 1`, for timing updates where every row changes.
    public func rotatingContent(step: Int, count: Int = 9) -> ListContent {
        let rows = (0..<count).map { offset -> ListRow in
            let item = items[(step * count + offset) % items.count]
            let title = item.title
            let length = (title as NSString).length
            return row(item, highlights: [HighlightRange(location: step % 3, length: min(2, max(0, length - 2)))])
        }
        return ListContent(sections: [ListSection(rows: rows)], emphasizesMatches: true)
    }

    private func row(_ item: Item, highlights: [HighlightRange]) -> ListRow {
        ListRow(
            id: item.id, title: item.title, titleHighlights: highlights, subtitle: item.subtitle,
            accessories: item.accessories, icon: item.icon)
    }

    /// A subsequence match that prefers word starts. Returns nil when the title does not contain
    /// every query character in order.
    static func match(_ needle: [UInt16], in title: String) -> (score: Int, ranges: [HighlightRange])? {
        let haystack = Array(title.lowercased().utf16)
        guard !needle.isEmpty else { return (0, []) }
        var ranges: [HighlightRange] = []
        var position = 0
        var score = 0
        for unit in needle {
            guard let found = haystack[position...].firstIndex(of: unit) else { return nil }
            let wordStart = found == 0 || haystack[found - 1] == 32
            score += wordStart ? 10 : (found == position ? 5 : 1)
            if let last = ranges.last, last.location + last.length == found {
                ranges[ranges.count - 1].length += 1
            } else {
                ranges.append(HighlightRange(location: found, length: 1))
            }
            position = found + 1
        }
        return (score - haystack.count / 4, ranges)
    }

    /// A 64-pixel icon: a rounded tile with a white symbol.
    public static func icon(symbol: String, hue: Double, muted: Bool) -> CGImage? {
        let pixels = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }
        let rect = CGRect(x: 4, y: 4, width: 56, height: 56)
        let tile = CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil)
        let top = NSColor(hue: hue, saturation: muted ? 0.08 : 0.55, brightness: muted ? 0.62 : 0.95, alpha: 1)
        let bottom = NSColor(hue: hue, saturation: muted ? 0.1 : 0.75, brightness: muted ? 0.42 : 0.72, alpha: 1)
        context.addPath(tile)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])
        {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 60), end: CGPoint(x: 0, y: 4), options: [])
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            configuration)
        {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let size = image.size
            image.draw(
                in: CGRect(x: 32 - size.width / 2, y: 32 - size.height / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }
}
