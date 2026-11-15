import Foundation
import Kit

/// Invented photos for a grid: tiles drawn from SF Symbols.
@MainActor final class DemoPhotos: ListSource {
    func load(_ request: ListRequest) async throws -> ListResult {
        let symbols = [
            "sun.horizon", "mountain.2", "leaf", "cloud.sun", "drop", "flame", "snowflake", "moon.stars", "tree",
            "water.waves", "bird", "fish",
        ]
        let names = ["Harbor", "Summit", "Meadow", "Coast", "Rain", "Ember", "Frost", "Night", "Grove", "Tide"]
        func tiles(_ prefix: String, _ range: Range<Int>) -> [Row] {
            range.map { index in
                Row(
                    id: ItemID("photo", "\(prefix)\(index)"), title: "\(names[index % names.count]) \(index + 1)",
                    subtitle: "\(index % 4 + 1) MB", icon: .symbol(symbols[index % symbols.count]))
            }
        }
        return ListResult(sections: [
            ListSection("This Week", id: "week", showsCount: true, rows: tiles("w", 0..<9)),
            ListSection("Earlier", id: "earlier", showsCount: true, rows: tiles("e", 9..<30)),
        ])
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Open", id: "open", icon: .symbol("photo")) { _ in .close() },
            Action("Copy Image", id: "copy", icon: .symbol("doc.on.doc"), shortcut: .copy) { _ in .keepOpen },
        ]
    }
}

/// Invented notes with a Markdown detail and metadata beside the list.
@MainActor final class DemoNotes: ListSource {
    private let notes: [(title: String, body: String, tags: [String])] = [
        (
            "Release checklist",
            "# Release checklist\n\n- Update the changelog\n- Run the **full** test suite\n"
                + "- Tag the build with `v2.4`\n\nShip once the captures look right.", ["work", "release"]
        ),
        ("Reading list", "# Reading list\n\n1. A book about typography\n2. Notes on colour", ["personal"]),
        ("Trip ideas", "# Trip ideas\n\nA coastal walk, a mountain hut, a small museum.", ["travel"]),
        ("Recipe: lentil soup", "# Lentil soup\n\nOnion, carrot, lentils, stock. *Simmer* for 25 minutes.", ["food"]),
        ("Meeting notes", "# Design review\n\nDecided to keep the glass panel fixed in height.", ["work"]),
    ]

    func load(_ request: ListRequest) async throws -> ListResult {
        let rows = notes.enumerated().map { index, note in
            Row(
                id: ItemID("note", String(index)), title: note.title, icon: .symbol("note.text"),
                accessories: [.tag(note.tags[0], color: .orange)])
        }
        return ListResult(rows: rows)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let index = Int(row.id.key), notes.indices.contains(index) else { return nil }
        let note = notes[index]
        return Detail(
            .markdown(note.body),
            metadata: [
                .label("Words", value: String(note.body.split(separator: " ").count)),
                .tags("Tags", note.tags.map { Tag($0, color: .orange) }), .separator,
                .label("Folder", value: "Notes"),
            ])
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open Note", id: "open", icon: .symbol("note.text")) { _ in .close() }]
    }
}

/// An answer that streams in a few words at a time.
@MainActor final class DemoAnswer: DetailSource {
    private static let answer = """
        ## How the panel stays sharp

        The window is one **Liquid Glass** slab. Text drawn with Core Text is not vibrant, so the theme \
        sets a tint that keeps titles above a contrast of 4.5 to 1.

        - The glass never resizes while you type.
        - Overlays live *inside* the panel, so it keeps key status.
        - Streaming text like this draws at most once per frame.
        """

    var followUp: FollowUp? { FollowUp(placeholder: "Ask a follow-up question") }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let words = Self.answer.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(
                    .metadata([.label("Model", value: "Example model"), .label("Tokens", value: "212")]))
                for (index, word) in words.enumerated() {
                    try await Task.sleep(for: .milliseconds(12))
                    continuation.yield(.append(index == 0 ? word : " " + word))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func actions(for detail: Detail) -> [Action] {
        [
            Action("Copy Answer", id: "copy", icon: .symbol("doc.on.doc")) { _ in .keepOpen },
            Action("Continue in Chat", id: "chat", icon: .symbol("bubble.left")) { _ in .keepOpen },
        ]
    }
}

/// Forms for the demo.
enum DemoForms {
    static let quicklink = FormPage(
        title: "Create Quicklink",
        fields: [
            .text("name", title: "Name", placeholder: "Docs search", initial: "Docs search", isRequired: true),
            .text(
                "link", title: "Link", placeholder: "https://example.com/search?q={query}",
                initial: "https://example.com/search?q={query", highlightsPlaceholders: true,
                info: "Use {query} where the typed text goes."),
            .dropdown(
                "browser", title: "Open With", options: [.init("Default Browser", value: "default"), .init("Harbor")]),
            .checkbox("pinned", title: "Favorites", label: "Show in favorites", initial: true),
            .tags("tags", title: "Tags", initial: ["docs", "search"]),
        ],
        submitTitle: "Save Quicklink",
        validate: { values in
            let link = values.text("link")
            guard let open = link.lastIndex(of: "{"), !link[open...].contains("}") else { return [:] }
            let start = link.utf16.distance(from: link.startIndex, to: open)
            return ["link": FieldError("This placeholder is not closed", range: start..<link.utf16.count)]
        },
        submit: { _, _ in .pop })
}

/// Invented files with a type dropdown and a notice about limited access.
@MainActor final class DemoFiles: ListSource {
    static let kinds = FilterDropdown(
        title: "Kind",
        options: [
            FilterOption(id: "all", title: "All Kinds"), FilterOption(id: "doc", title: "Documents", section: "Kind"),
            FilterOption(id: "image", title: "Images", section: "Kind"),
            FilterOption(id: "folder", title: "Folders", section: "Kind"),
        ])

    func load(_ request: ListRequest) async throws -> ListResult {
        let files: [(String, String, String)] = [
            ("Quarterly plan.pages", "doc", "doc.richtext"), ("Harbor at dusk.heic", "image", "photo"),
            ("Invoices", "folder", "folder"), ("Budget 2027.numbers", "doc", "tablecells"),
            ("Logo draft.png", "image", "photo"), ("Notes from the trip.md", "doc", "doc.text"),
        ]
        let rows = files.filter { request.filter == nil || request.filter == "all" || $0.1 == request.filter }.map {
            Row(id: ItemID("file", $0.0), title: $0.0, subtitle: "~/Example", icon: .symbol($0.2))
        }
        return ListResult(
            rows: rows,
            notice: Notice(
                icon: .symbol("lock.shield"), title: "Search is limited", message: "Grant Full Disk Access",
                action: Action("Grant Access", id: "grant") { _ in .keepOpen }))
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Open", id: "open", icon: .symbol("arrow.up.forward.app")) { _ in .close() },
            Action("Quick Look", id: "quick-look", icon: .symbol("eye"), shortcut: .quickLook) { _ in .keepOpen },
        ]
    }
}
