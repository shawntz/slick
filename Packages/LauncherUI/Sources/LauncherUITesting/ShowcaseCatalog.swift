import AppKit
import LauncherUI

/// Sample content for product shots: invented apps with finished-looking icons, the commands and
/// files a launcher shows, a Markdown note, a folder of generated pictures and a command's form.
///
/// Every name is made up and nothing is read from the machine. The pictures this content appears
/// in must say that the catalog is sample data.
public enum ShowcaseCatalog {
    // MARK: Apps

    /// An invented app: its name, symbol and tile colours.
    struct App {
        let name: String
        let symbol: String
        let top: UInt32
        let bottom: UInt32
        var glyph: UInt32 = 0xFFFFFF
    }

    static let apps: [App] = [
        App(name: "Cadence Calendar", symbol: "calendar", top: 0xFF7A70, bottom: 0xE0334A),
        App(name: "Canvas Sketch", symbol: "paintbrush.pointed.fill", top: 0xFFC95A, bottom: 0xF2741B),
        App(name: "Cascade Mail", symbol: "envelope.fill", top: 0x72CCFF, bottom: 0x2A72EE),
        App(name: "Caravan Maps", symbol: "map.fill", top: 0x74E6AE, bottom: 0x18A26B),
        App(name: "Cameo Photos", symbol: "camera.aperture", top: 0xFF92CB, bottom: 0xD2337E),
        App(name: "Coral Weather", symbol: "cloud.sun.fill", top: 0x86DAFF, bottom: 0x3B7EF6),
        App(name: "Aurora Notes", symbol: "note.text", top: 0xFFE37E, bottom: 0xF4B100, glyph: 0x6E4C00),
        App(name: "Quill Writer", symbol: "pencil.line", top: 0xBBA4FF, bottom: 0x6B45E4),
        App(name: "Cobalt Terminal", symbol: "terminal.fill", top: 0x535866, bottom: 0x16181E),
        App(name: "Drift Browser", symbol: "globe", top: 0x8C9BFF, bottom: 0x4A3BD6),
        App(name: "Juniper Tasks", symbol: "checklist", top: 0x66E3D2, bottom: 0x0F9C93),
        App(name: "Fable Music", symbol: "music.note", top: 0xFF8399, bottom: 0xE0284E),
    ]

    private static var iconCache: [String: CGImage] = [:]

    /// The icon of an invented app, or a utility tile for anything else.
    public static func icon(_ name: String) -> CGImage? {
        if let cached = iconCache[name] { return cached }
        let image: CGImage?
        if let app = apps.first(where: { $0.name == name }) {
            image = ShowcaseIcons.app(app.symbol, top: app.top, bottom: app.bottom, glyph: app.glyph)
        } else {
            image = ShowcaseIcons.utility(name == "Search Files" ? "doc.text.magnifyingglass" : "command")
        }
        iconCache[name] = image
        return image
    }

    private static func row(
        _ id: UInt64, _ title: String, _ subtitle: String, query: String = "", accessories: [RowAccessory] = [],
        icon: CGImage? = nil
    ) -> ListRow {
        let highlights =
            query.isEmpty ? [] : SyntheticCatalog.match(Array(query.lowercased().utf16), in: title)?.ranges ?? []
        return ListRow(
            id: id, title: title, titleHighlights: highlights, subtitle: subtitle, accessories: accessories,
            icon: icon ?? Self.icon(title))
    }

    private static let running = RowAccessory.tag("Running", color: ThemeColor(.green))

    // MARK: Root search

    /// What the hero shot has typed.
    public static let heroQuery = "ca"

    /// The rest of the top result's title, shown as the ghost completion.
    public static let heroGhost = "dence Calendar"

    /// Results for ``heroQuery``: apps that start with it, a file, and two loose matches.
    public static func heroResults() -> ListContent {
        let q = heroQuery
        let rows = [
            row(1, "Cadence Calendar", "Application", query: q, accessories: [running]),
            row(2, "Canvas Sketch", "Application", query: q, accessories: [.keycaps(["⌥", "⌘", "S"])]),
            row(3, "Cascade Mail", "Application", query: q, accessories: [running]),
            row(4, "Caravan Maps", "Application", query: q),
            row(5, "Cameo Photos", "Application", query: q, accessories: [.text("Alias: cam")]),
            row(
                6, "Canyon Trip.md", "Documents", query: q, accessories: [.text("Yesterday")],
                icon: ShowcaseIcons.document("text.alignleft", accent: 0x7B4BEA)),
            row(7, "Coral Weather", "Application", query: q),
            row(
                8, "Quick Capture", "Aurora Notes", query: q, accessories: [.keycaps(["⌥", "⌘", "N"])],
                icon: icon("Aurora Notes")),
        ]
        return ListContent(sections: [ListSection(rows: rows)], emphasizesMatches: true)
    }

    /// Results for any query, for clips that type one letter at a time: every sample app and
    /// command whose title holds the query's letters in order, best first, at most eight.
    public static func results(for query: String) -> ListContent {
        guard !query.isEmpty else { return suggestions() }
        let needle = Array(query.lowercased().utf16)
        var pool = apps.enumerated().map { index, app in (UInt64(100 + index), app.name, "Application") }
        pool.append((120, "Quick Capture", "Aurora Notes"))
        pool.append((121, "Search Files", "Command"))
        let scored = pool.compactMap { id, title, subtitle -> (score: Int, row: ListRow)? in
            guard let match = SyntheticCatalog.match(needle, in: title) else { return nil }
            let icon = subtitle == "Aurora Notes" ? Self.icon("Aurora Notes") : Self.icon(title)
            return (match.score, row(id, title, subtitle, query: query, icon: icon))
        }
        let rows = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.row.title < $1.row.title }
            .prefix(8).map(\.row)
        return ListContent(sections: [ListSection(rows: Array(rows))], emphasizesMatches: true)
    }

    /// The rest of the top result's title after `query`, when the title starts with it.
    public static func ghost(for query: String) -> String {
        guard let top = results(for: query).sections.first?.rows.first?.title,
            top.lowercased().hasPrefix(query.lowercased())
        else { return "" }
        return String(top.dropFirst(query.count))
    }

    /// The empty query: Suggested, then Favorites.
    public static func suggestions() -> ListContent {
        ListContent(sections: [
            ListSection(
                title: "Suggested",
                rows: [
                    row(11, "Cascade Mail", "Application", accessories: [running]),
                    row(12, "Cadence Calendar", "Application", accessories: [running]),
                    row(13, "Quill Writer", "Application"),
                    row(14, "Cobalt Terminal", "Application", accessories: [running]),
                    row(15, "Fable Music", "Application"),
                ]),
            ListSection(
                title: "Favorites",
                rows: [
                    row(21, "Aurora Notes", "Application", accessories: [.keycaps(["⌥", "⌘", "A"])]),
                    row(22, "Drift Browser", "Application", accessories: [.keycaps(["⌥", "⌘", "B"])]),
                    row(23, "Juniper Tasks", "Application", accessories: [.text("Alias: todo")]),
                    row(24, "Search Files", "Command", accessories: [.text("Alias: f")]),
                ]),
        ])
    }

    /// The selected app's actions.
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
            title: "Application",
            items: [
                ActionItem(id: "copy", title: "Copy Path", icon: .symbol("doc.on.doc"), keys: ["⇧", "⌘", "C"]),
                ActionItem(id: "hide", title: "Hide Application", icon: .symbol("eye.slash")),
                ActionItem(
                    id: "quit", title: "Force Quit", icon: .symbol("xmark.octagon"), keys: ["⌃", "⌥", "Q"],
                    isDestructive: true),
            ]),
    ])

    // MARK: Files and preview

    /// What the detail shot has typed.
    public static let fileQuery = "plan"

    /// File results for ``fileQuery``.
    public static func fileRows() -> ListContent {
        let q = fileQuery
        let markdown = ShowcaseIcons.document("text.alignleft", accent: 0x7B4BEA)
        let rows = [
            row(31, "Atlas launch plan.md", "", query: q, accessories: [.text("Markdown")], icon: markdown),
            row(
                32, "Garden plan.pdf", "", query: q, accessories: [.text("PDF")],
                icon: ShowcaseIcons.document("doc.richtext", accent: 0xE0334A)),
            row(33, "Lisbon trip plan.md", "", query: q, accessories: [.text("Markdown")], icon: markdown),
            row(
                34, "Floor plan.png", "", query: q, accessories: [.text("Image")],
                icon: ShowcaseIcons.document("photo", accent: 0x0F9C93)),
            row(
                35, "Meal plan.csv", "", query: q, accessories: [.text("Table")],
                icon: ShowcaseIcons.document("tablecells", accent: 0x18A26B)),
            row(36, "Planning", "", query: q, accessories: [.text("Folder")], icon: ShowcaseIcons.folder()),
            row(
                37, "plan-notes.txt", "", query: q, accessories: [.text("Text")],
                icon: ShowcaseIcons.document("doc.text", accent: 0x2A72EE)),
        ]
        return ListContent(sections: [ListSection(rows: rows)], emphasizesMatches: true)
    }

    /// The selected file's text.
    public static let markdown = """
        # Atlas launch plan
        The beta opens on **Monday** for 40 testers. Keep the scope *small* and run `make check` before every build.

        ## This week
        1. Freeze the feature list.
        2. Record the walkthrough.
        3. Send the invites, then [collect feedback](https://example.com/atlas).

        - Fix the two open crash reports.
        - Write the release notes last.

        ```
        make release VERSION=0.9.0
        ```
        """

    /// The selected file's details.
    public static let metadata: [MetadataItem] = [
        .label("Kind", value: "Markdown document"),
        .label("Size", value: "3 KB"),
        .label("Where", value: "Documents › Atlas"),
        .tags(
            "Tags",
            [MetadataTag("Planning", color: ThemeColor(.purple)), MetadataTag("Team", color: ThemeColor(.blue))]),
        .separator,
        .label("Created", value: "Monday at 14:05"),
        .label("Modified", value: "Today at 09:41"),
    ]

    /// Filter options for file search.
    public static let fileKinds: [MenuOption] = [
        MenuOption(id: "all", title: "All Kinds", icon: .symbol("square.grid.2x2")),
        MenuOption(id: "documents", title: "Documents", icon: .symbol("doc.text"), section: "Kinds"),
        MenuOption(id: "images", title: "Images", icon: .symbol("photo"), section: "Kinds"),
        MenuOption(id: "folders", title: "Folders", icon: .symbol("folder"), section: "Kinds"),
    ]

    // MARK: Picture grid

    /// A folder of generated abstract pictures, five across.
    ///
    /// Ten by default, in two rows. In a 2x capture each picture costs about 40 KB of PNG, because
    /// what the grid view draws reaches the screen with one level of noise, so fifteen pushed a
    /// product shot over its size budget.
    public static func pictureGrid(count: Int = 10) -> GridContent {
        let featured = ["Aurora", "Dune", "Lagoon", "Ember", "Glacier", "Meadow", "Nebula", "Dusk", "Tide", "Coral"]
        let ordered =
            featured.compactMap { name in pictures.first { $0.name == name } }
            + pictures.filter { !featured.contains($0.name) }
        let cells = ordered.prefix(count).enumerated().map { index, picture in
            GridCell(
                id: UInt64(100 + index),
                content: .image(ShowcaseArt.render(picture.recipe, pixels: CGSize(width: 320, height: 200))),
                title: "\(picture.name).png", subtitle: "3840 × 2400")
        }
        return GridContent(
            sections: [GridSection(title: "Wallpapers", cells: cells)], columns: .image, aspectRatio: 1.6,
            showsTitles: true)
    }

    private typealias Glow = ShowcaseArt.Glow
    private typealias Wave = ShowcaseArt.Wave

    private static func g(_ x: Double, _ y: Double, _ radius: Double, _ color: UInt32, _ alpha: Double) -> Glow {
        Glow(x, y, radius: radius, color, alpha: alpha)
    }

    private static func w(
        _ level: Double, _ amplitude: Double, _ frequency: Double, _ phase: Double, _ color: UInt32,
        _ alpha: Double = 1
    ) -> Wave {
        Wave(level: level, amplitude: amplitude, frequency: frequency, phase: phase, color, alpha: alpha)
    }

    private static func swirl(_ color: UInt32, width: Double, alpha: Double, rising: Bool) -> ShowcaseArt.Ribbon {
        let points =
            rising
            ? [
                CGPoint(x: -0.1, y: 0.80), CGPoint(x: 0.30, y: 0.30), CGPoint(x: 0.65, y: 0.90),
                CGPoint(x: 1.1, y: 0.25),
            ]
            : [
                CGPoint(x: -0.1, y: 0.30), CGPoint(x: 0.35, y: 0.75), CGPoint(x: 0.70, y: 0.15),
                CGPoint(x: 1.1, y: 0.65),
            ]
        return ShowcaseArt.Ribbon(points, width: width, color, alpha: alpha, additive: true)
    }

    /// Fifteen abstract pictures: glows, aurora swirls, dunes, hills and water.
    private static let pictures: [(name: String, recipe: ShowcaseArt.Recipe)] = [
        (
            "Aurora",
            .init(
                topLeft: 0x06142E, bottomRight: 0x0B2A3F,
                glows: [
                    g(0.25, 0.25, 0.5, 0x2EE6C5, 0.7), g(0.75, 0.2, 0.4, 0x7CF29A, 0.45),
                    g(0.9, 0.9, 0.5, 0x8743FA, 0.6),
                ],
                ribbons: [swirl(0x2EE6C5, width: 0.08, alpha: 0.06, rising: true)])
        ),
        (
            "Dune",
            .init(
                topLeft: 0xFBD9B0, bottomRight: 0xF0A877, glows: [g(0.72, 0.22, 0.2, 0xFFF4D6, 0.95)],
                waves: [
                    w(0.55, 0.06, 0.8, 0.1, 0xE9A06B), w(0.68, 0.07, 1.1, 0.4, 0xD7804D),
                    w(0.84, 0.05, 0.9, 0.7, 0xB9603A),
                ])
        ),
        (
            "Lagoon",
            .init(
                topLeft: 0x8EE8F5, bottomRight: 0x1C7FC4, glows: [g(0.3, 0.2, 0.4, 0xFFFFFF, 0.5)],
                waves: [
                    w(0.50, 0.03, 1.6, 0.2, 0x3CB8E6, 0.8), w(0.63, 0.035, 1.3, 0.5, 0x1E8FD0, 0.85),
                    w(0.78, 0.03, 1.9, 0.8, 0x0D5EA6, 0.9),
                ])
        ),
        (
            "Ember",
            .init(
                topLeft: 0x2A0606, bottomRight: 0x0E0303,
                glows: [
                    g(0.2, 0.8, 0.5, 0xFF6B35, 0.8), g(0.8, 0.3, 0.4, 0xD7263D, 0.7),
                    g(0.55, 0.55, 0.25, 0xFFB347, 0.5),
                ],
                ribbons: [swirl(0xFF8A4C, width: 0.06, alpha: 0.05, rising: false)])
        ),
        (
            "Glacier",
            .init(
                topLeft: 0xF4FAFF, bottomRight: 0xC9E2F5, glows: [g(0.8, 0.15, 0.3, 0xD9CCFF, 0.6)],
                waves: [
                    w(0.45, 0.10, 0.6, 0.15, 0xFFFFFF, 0.9), w(0.62, 0.08, 0.8, 0.55, 0xDCEEFB, 0.95),
                    w(0.80, 0.06, 0.7, 0.3, 0xB3D4F0),
                ])
        ),
        (
            "Meadow",
            .init(
                topLeft: 0xFFF6D0, bottomRight: 0xCDEFB0, glows: [g(0.25, 0.22, 0.2, 0xFFF3A0, 0.9)],
                waves: [
                    w(0.55, 0.06, 0.7, 0.0, 0xA8DC7A), w(0.68, 0.07, 0.9, 0.45, 0x76C25C),
                    w(0.84, 0.05, 1.1, 0.8, 0x3E9B48),
                ])
        ),
        (
            "Nebula",
            .init(
                topLeft: 0x0E0428, bottomRight: 0x22073E,
                glows: [
                    g(0.3, 0.4, 0.45, 0xFF4FD8, 0.55), g(0.7, 0.6, 0.45, 0x7B2FF7, 0.7),
                    g(0.85, 0.2, 0.3, 0x2EC5FF, 0.5),
                    g(0.15, 0.85, 0.3, 0x5A1FD1, 0.6),
                ])
        ),
        (
            "Orchard",
            .init(
                topLeft: 0xFFEAF0, bottomRight: 0xFFD3DE,
                glows: [
                    g(0.2, 0.3, 0.4, 0xFF8FAB, 0.6), g(0.8, 0.7, 0.45, 0xFFD6A5, 0.75), g(0.6, 0.2, 0.3, 0xFFFFFF, 0.7),
                ])
        ),
        (
            "Prism",
            .init(
                topLeft: 0xFBF7FF, bottomRight: 0xEAF6FF,
                glows: [
                    g(0.15, 0.25, 0.35, 0xFF9AD5, 0.6), g(0.45, 0.75, 0.4, 0x9AD0FF, 0.65),
                    g(0.8, 0.3, 0.35, 0xFFE39A, 0.6),
                    g(0.9, 0.85, 0.3, 0xB8FFCF, 0.6),
                ])
        ),
        (
            "Tide",
            .init(
                topLeft: 0x062A4A, bottomRight: 0x02101F, glows: [g(0.7, 0.2, 0.35, 0x9BE7FF, 0.35)],
                waves: [
                    w(0.45, 0.05, 1.2, 0.3, 0x0B4F7A, 0.9), w(0.60, 0.05, 1.5, 0.6, 0x0A6A95, 0.9),
                    w(0.76, 0.04, 1.1, 0.1, 0x1EA3C8, 0.85), w(0.90, 0.03, 1.7, 0.5, 0x37C6E0, 0.8),
                ])
        ),
        (
            "Dusk",
            .init(
                topLeft: 0x2B1055, bottomRight: 0xF08A6B, glows: [g(0.5, 0.55, 0.25, 0xFFC48A, 0.9)],
                waves: [
                    w(0.62, 0.05, 0.8, 0.2, 0x5B2A86), w(0.75, 0.06, 1.0, 0.6, 0x3B1A63),
                    w(0.88, 0.04, 0.7, 0.9, 0x22103F),
                ])
        ),
        (
            "Fern",
            .init(
                topLeft: 0x0C2A1A, bottomRight: 0x041A0F,
                glows: [g(0.25, 0.3, 0.45, 0x58F29B, 0.45), g(0.8, 0.75, 0.45, 0x1B998B, 0.6)],
                ribbons: [swirl(0xC9F2A6, width: 0.06, alpha: 0.035, rising: true)])
        ),
        (
            "Slate",
            .init(
                topLeft: 0x3B4A5C, bottomRight: 0x1C2531, glows: [g(0.75, 0.2, 0.3, 0xAAB7C8, 0.4)],
                waves: [
                    w(0.55, 0.07, 0.6, 0.3, 0x4D5D70), w(0.70, 0.06, 0.8, 0.7, 0x36424F),
                    w(0.85, 0.05, 0.9, 0.1, 0x252E39),
                ])
        ),
        (
            "Coral",
            .init(
                topLeft: 0xFFB4A2, bottomRight: 0xFF6F61,
                glows: [
                    g(0.2, 0.2, 0.4, 0xFFE5DC, 0.8), g(0.85, 0.85, 0.45, 0xFF4D6D, 0.6),
                    g(0.7, 0.25, 0.3, 0xFFD3A1, 0.6),
                ])
        ),
        (
            "Mist",
            .init(
                topLeft: 0xF2F4F8, bottomRight: 0xD5DDEA, glows: [g(0.3, 0.25, 0.35, 0xE8DCFF, 0.6)],
                waves: [
                    w(0.50, 0.08, 0.5, 0.2, 0xFFFFFF, 0.7), w(0.66, 0.07, 0.7, 0.6, 0xE6EBF3, 0.9),
                    w(0.82, 0.05, 0.8, 0.9, 0xC7D2E3, 0.95),
                ])
        ),
    ]

    // MARK: Form

    /// A command's form: a new note for the invented Aurora Notes, with six kinds of field.
    public static func noteForm() -> FormContent {
        FormContent(items: [
            FormItem(
                id: "title", label: "Title", kind: .text(placeholder: "Note title"), value: .text("Atlas launch plan")),
            FormItem(
                id: "folder", label: "Folder",
                kind: .dropdown([
                    MenuOption(id: "projects", title: "Projects"), MenuOption(id: "inbox", title: "Inbox"),
                ]), value: .option("projects")),
            FormItem(id: "tags", label: "Tags", kind: .tags(placeholder: "Add tag"), value: .tags(["launch", "team"])),
            FormItem(
                id: "body", label: "Note", kind: .multiline(placeholder: "Write something"),
                value: .text(
                    "The beta opens on Monday for 40 testers. Collect feedback in one place and fix the two open crash reports first."
                )),
            FormItem(
                id: "file", label: "Attachment", kind: .filePath(placeholder: "Choose a file", buttonTitle: "Choose…"),
                value: .text("~/Desktop/walkthrough.mov")),
            FormItem(id: "separator", label: "", kind: .separator),
            FormItem(id: "pin", label: "", kind: .checkbox(label: "Pin to the top of the list"), value: .bool(true)),
            FormItem(
                id: "hotkey", label: "Hotkey", kind: .hotkey(placeholder: "Record Shortcut"),
                value: .hotkey(KeyChord("n", [.option, .command])), info: "Opens this form from any app"),
        ])
    }
}
