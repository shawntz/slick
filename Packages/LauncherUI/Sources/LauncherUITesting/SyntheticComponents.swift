import AppKit
import LauncherUI

/// Invented content for the grid, the detail pane, the cards and forms, for captures, benchmarks
/// and tests. Nothing is read from the machine.
public enum SyntheticComponents {
    // MARK: Grid

    /// Emoji and symbol characters from the standard blocks, for glyph grids.
    public static let glyphs: [String] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6C5, 0x1F90C...0x1F9FF,
        ]
        return ranges.flatMap { $0 }.compactMap { scalar -> String? in
            guard let unicode = Unicode.Scalar(scalar), unicode.properties.isEmojiPresentation else { return nil }
            return String(unicode)
        }
    }()

    private static let syllables = [
        "amber", "brisk", "cedar", "dune", "ember", "fern", "glint", "harbor", "iris", "jade", "kite", "lumen", "moss",
        "nova", "opal", "pine", "quartz", "reed", "sage", "tide", "umber", "vale", "wren", "yarrow", "zephyr",
    ]

    /// `count` glyph cells with invented two-word titles, for filtering benchmarks.
    public static func glyphCells(count: Int) -> [GridCell] {
        (0..<count).map { index in
            let first = syllables[index % syllables.count]
            let second = syllables[(index / syllables.count + index * 7) % syllables.count]
            return GridCell(
                id: UInt64(index + 1), content: .glyph(glyphs[index % glyphs.count]), title: "\(first) \(second)")
        }
    }

    /// `count` cells showing pre-rendered glyph images, as an icon atlas would supply them: `distinct`
    /// images rendered once and reused in turn.
    public static func glyphImageCells(count: Int, distinct: Int = 300, pixels: Int = 140) -> [GridCell] {
        let images = (0..<distinct).map { glyphImage(glyphs[$0 % glyphs.count], pixels: pixels) }
        return glyphCells(count: count).enumerated().map { index, cell in
            var cell = cell
            cell.content = .image(images[index % distinct])
            return cell
        }
    }

    /// One glyph rendered into a square bitmap.
    public static func glyphImage(_ glyph: String, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let font = NSFont.systemFont(ofSize: CGFloat(pixels) * 0.8)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: (CGFloat(pixels) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(pixels) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// A glyph grid in two titled sections.
    public static func glyphGrid() -> GridContent {
        let cells = glyphCells(count: 40)
        return GridContent(
            sections: [
                GridSection(title: "Frequently Used", cells: Array(cells.prefix(8))),
                GridSection(title: "Smileys and Nature", cells: Array(cells.dropFirst(8))),
            ], columns: .glyph, showsTitles: true)
    }

    /// The cells of `cells` whose titles contain every character of `query` in order, with their
    /// matched characters highlighted. A stand-in for the engine.
    public static func filter(_ cells: [GridCell], by query: String) -> [GridCell] {
        let needle = Array(query.lowercased().utf16)
        guard !needle.isEmpty else { return cells }
        return cells.compactMap { cell in
            guard let match = SyntheticCatalog.match(needle, in: cell.title) else { return nil }
            var copy = cell
            copy.titleHighlights = match.ranges
            return copy
        }
    }

    /// An image grid of generated pictures, five across, with titles and subtitles.
    public static func imageGrid() -> GridContent {
        let names = [
            "Harbor Dawn", "Cedar Ridge", "Quartz Bay", "Fern Hollow", "Lumen Fields", "Opal Coast",
            "Moss Canyon", "Tide Pools", "Amber Dunes", "Wren Valley",
        ]
        let cells = names.enumerated().map { index, name in
            GridCell(
                id: UInt64(index + 1), content: .image(picture(seed: index)), title: name,
                subtitle: "\(1200 + index * 160) × \(800 + index * 90)")
        }
        return GridContent(
            sections: [GridSection(title: "Screenshots", cells: cells)], columns: .image, showsTitles: true)
    }

    /// A generated landscape: a sky gradient, a sun and two hills.
    public static func picture(seed: Int, width: Int = 320, height: Int = 220) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let hue = Double((seed * 29) % 100) / 100
        let top = NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(
            hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.75, alpha: 1
        )
        .cgColor
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        }
        context.setFillColor(NSColor(hue: 0.12, saturation: 0.7, brightness: 1, alpha: 0.9).cgColor)
        let sun = CGFloat(30 + seed % 4 * 6)
        context.fillEllipse(
            in: CGRect(x: CGFloat(60 + seed * 23 % 180), y: CGFloat(height) * 0.62, width: sun, height: sun))
        for (index, shade) in [0.35, 0.22].enumerated() {
            context.setFillColor(
                NSColor(
                    hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: shade + 0.2,
                    alpha: 1
                ).cgColor)
            context.fillEllipse(
                in: CGRect(
                    x: CGFloat(-80 + index * 160), y: CGFloat(-height / 2), width: CGFloat(width),
                    height: CGFloat(height) * 0.9))
        }
        return context.makeImage()
    }

    // MARK: Detail

    /// A Markdown answer with every construct the pane draws.
    public static let markdown = """
        # Release checklist
        Three steps keep a release **calm** and *predictable*. Run `make check` before anything else.

        ## Steps
        1. Freeze the branch and tag the build.
        2. Run the smoke suite on a clean account.
        3. Write the notes, then [publish them](https://example.com/notes).

        - Keep the changelog short.
        - Link every fixed issue.

        > Ship small changes often.

        ```
        make release VERSION=2.4.0
        make notes > notes.md
        ```
        """

    /// Metadata with every kind of row.
    public static let metadata: [MetadataItem] = [
        .label("Source", value: "Quill Writer"),
        .label("Characters", value: "412"),
        .tags(
            "Labels", [MetadataTag("Draft", color: ThemeColor(.orange)), MetadataTag("Team", color: ThemeColor(.blue))]),
        .separator,
        .color("Accent", ThemeColor(red: 0.2, green: 0.55, blue: 0.95), text: "#338CF2"),
        .link("Reference", text: "example.com/notes", url: "https://example.com/notes"),
        .label("Copied", value: "Today at 09:41"),
    ]

    /// Rows for a list beside a detail pane, like clipboard history.
    public static func historyRows() -> ListContent {
        let titles = [
            "Release checklist", "make release VERSION=2.4.0", "Meeting moved to Thursday", "#338CF2",
            "harbor-dawn.png",
            "Pack my box with five dozen jugs", "https://example.com/notes", "42 × 18 = 756",
        ]
        let kinds = ["Text", "Text", "Text", "Color", "Image", "Text", "Link", "Text"]
        let rows = titles.enumerated().map { index, title in
            ListRow(
                id: UInt64(index + 1), title: title, subtitle: "", accessories: [.text(kinds[index])],
                icon: SyntheticCatalog.icon(
                    symbol: index == 4 ? "photo.fill" : "doc.on.clipboard.fill", hue: 0.55, muted: true))
        }
        return ListContent(sections: [ListSection(title: "Today", rows: rows)])
    }

    // MARK: Cards and forms

    /// An item's actions in three sections, with shortcuts and a destructive one.
    public static let actions = ActionCardContent(sections: [
        ActionSection(items: [
            ActionItem(id: "open", title: "Open Application", icon: .symbol("arrow.up.forward.app"), keys: ["↩"]),
            ActionItem(id: "reveal", title: "Show in Finder", icon: .symbol("folder"), keys: ["⌘", "↩"]),
        ]),
        ActionSection(
            title: "Organize",
            items: [
                ActionItem(id: "favorite", title: "Add to Favorites", icon: .symbol("star"), keys: ["⌘", "F"]),
                ActionItem(id: "alias", title: "Set Alias", icon: .symbol("textformat"), keys: ["⌘", "E"]),
                ActionItem(id: "hotkey", title: "Set Hotkey", icon: .symbol("keyboard"), keys: ["⌥", "⌘", "H"]),
            ]),
        ActionSection(
            title: "Danger Zone",
            items: [
                ActionItem(id: "reset", title: "Reset Ranking", icon: .symbol("arrow.counterclockwise")),
                ActionItem(
                    id: "quit", title: "Force Quit", icon: .symbol("xmark.octagon"), keys: ["⌃", "⌥", "Q"],
                    isDestructive: true),
            ]),
    ])

    /// Filter options, as a clipboard history's type filter has.
    public static let filterOptions: [MenuOption] = [
        MenuOption(id: "all", title: "All Types", icon: .symbol("square.grid.2x2")),
        MenuOption(id: "text", title: "Text", icon: .symbol("text.alignleft"), section: "Types"),
        MenuOption(id: "image", title: "Images", icon: .symbol("photo"), section: "Types"),
        MenuOption(id: "link", title: "Links", icon: .symbol("link"), section: "Types"),
        MenuOption(id: "color", title: "Colors", icon: .symbol("paintpalette"), section: "Types"),
    ]

    /// A form with every kind of field, one of them showing an error.
    public static func form() -> FormContent {
        FormContent(items: [
            FormItem(id: "name", label: "Name", kind: .text(placeholder: "Quicklink name"), value: .text("Team notes")),
            FormItem(
                id: "link", label: "Link", kind: .text(placeholder: "https://"), value: .text("example.com/{query"),
                error: "The placeholder is missing a closing brace"),
            FormItem(id: "token", label: "Token", kind: .secure(placeholder: "Optional"), value: .text("swordfish")),
            FormItem(
                id: "note", label: "Note", kind: .multiline(placeholder: "What this link is for"),
                value: .text("Opens the shared notes for the current sprint.")),
            FormItem(
                id: "browser", label: "Open With",
                kind: .dropdown([
                    MenuOption(id: "default", title: "Default Browser"),
                    MenuOption(id: "drift", title: "Drift Browser"),
                ]), value: .option("drift")),
            FormItem(id: "pin", label: "", kind: .checkbox(label: "Show in Favorites"), value: .bool(true)),
            FormItem(id: "separator", label: "", kind: .separator),
            FormItem(
                id: "when", label: "Remind Me", kind: .date(includesTime: true),
                value: .date(Date(timeIntervalSinceReferenceDate: 815_000_000))),
            FormItem(
                id: "folder", label: "Folder", kind: .filePath(placeholder: "Choose a folder", buttonTitle: "Choose…"),
                value: .text("/Volumes/Shared/Atlas")),
            FormItem(id: "tags", label: "Tags", kind: .tags(placeholder: "Add tag"), value: .tags(["work", "sprint"])),
            FormItem(
                id: "hotkey", label: "Hotkey", kind: .hotkey(placeholder: "Record Shortcut"),
                value: .hotkey(KeyChord("n", [.option, .command])), info: "Opens the link from anywhere"),
        ])
    }
}
