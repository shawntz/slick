import Foundation
import Kit

/// Notes made into rows and sections, and searched. Pure, so it runs off the main thread.
nonisolated enum NoteRows {
    /// The IDs of the sections that are not days.
    static let pinnedSection = "pinned"
    static let titlesSection = "titles"
    static let textSection = "text"
    /// The most text matches that get a snippet; the rest show their first line. A snippet looks
    /// for its line in up to a megabyte of text, and only the first rows are seen at once.
    static let snippetLimit = 50

    /// One note's row. It stands for the note's file, so every feature's actions for files apply.
    static func row(
        _ note: NoteRecord, folder: URL, subtitle: String? = nil, highlights: [Range<Int>] = [],
        memory: RowMemory = .learnOnly
    ) -> Row {
        let url = folder.appending(path: note.fileName, directoryHint: .notDirectory)
        var accessories: [Accessory] = note.tags.prefix(2).map { .tag("#" + DisplayText.oneLine($0)) }
        accessories.append(.date(note.modified))
        let subtitle = subtitle ?? note.preview
        return Row(
            id: NoteIDs.row(note.fileName), title: note.title, subtitle: subtitle.isEmpty ? nil : subtitle,
            icon: .symbol(note.isDataless ? "icloud" : "note.text"), accessories: accessories,
            keywords: note.tags.map { "#" + $0 }, quickLookURL: note.isDataless ? nil : url,
            titleHighlights: highlights, memory: memory, represents: note.isDataless ? nil : .files([url]))
    }

    /// Search Notes' sections. With no query: Pinned, then one section per day the notes changed,
    /// newest first. With a query: the pinned notes that match, then the notes whose titles match,
    /// then those whose text matches, each newest first, with the title's matches highlighted and
    /// a snippet of the text around the match.
    @concurrent static func sections(
        _ index: NoteIndex, pinned: Set<String>, query: NoteQuery, days: DaySections
    ) async throws -> [ListSection] {
        let folder = index.folder.url
        if query.isEmpty {
            let pins = index.notes.filter { pinned.contains($0.fileName) }.map { row($0, folder: folder) }
            let rest = index.notes.filter { !pinned.contains($0.fileName) }
            var sections: [ListSection] = []
            if !pins.isEmpty { sections.append(ListSection(Strings.pinnedSection, id: pinnedSection, rows: pins)) }
            sections += days.sections(rest, date: \.modified) { row($0, folder: folder) }
            return sections
        }
        var pinnedTitles: [Row] = []
        var pinnedText: [Row] = []
        var titles: [Row] = []
        var text: [Row] = []
        var snippets = 0
        for (position, note) in index.notes.enumerated() {
            if position % 256 == 0 { try Task.checkCancellation() }
            let isPinned = pinned.contains(note.fileName)
            if query.folded.allSatisfy({ NoteSearch.contains(note.foldedTitle, $0) }) {
                let found = row(note, folder: folder, highlights: NoteSearch.highlights(query, in: note.title))
                if isPinned { pinnedTitles.append(found) } else { titles.append(found) }
                continue
            }
            guard let body = note.text,
                query.folded.allSatisfy({
                    NoteSearch.contains(note.foldedTitle, $0) || NoteSearch.contains(body.folded, $0)
                })
            else { continue }
            var snippet: String?
            if snippets < snippetLimit {
                snippet = NoteSearch.snippet(query, foldedTitle: note.foldedTitle, text: body)
                snippets += 1
            }
            let found = row(
                note, folder: folder, subtitle: snippet, highlights: NoteSearch.highlights(query, in: note.title))
            if isPinned { pinnedText.append(found) } else { text.append(found) }
        }
        try Task.checkCancellation()
        var sections: [ListSection] = []
        let pins = pinnedTitles + pinnedText
        if !pins.isEmpty { sections.append(ListSection(Strings.pinnedSection, id: pinnedSection, rows: pins)) }
        if !titles.isEmpty {
            sections.append(ListSection(Strings.titleMatchesSection, id: titlesSection, rows: titles))
        }
        if !text.isEmpty { sections.append(ListSection(Strings.textMatchesSection, id: textSection, rows: text)) }
        return sections
    }

    /// Every note as a row for root search, or for the Append to Note picker: pinned notes first.
    @concurrent static func all(_ index: NoteIndex, pinned: Set<String>) async -> [Row] {
        let folder = index.folder.url
        let pins = index.notes.filter { pinned.contains($0.fileName) }
        let rest = index.notes.filter { !pinned.contains($0.fileName) }
        return (pins + rest).enumerated().map { position, note in
            var made = row(note, folder: folder)
            // Newer notes and pins first among equal matches.
            made.rankHint = Double(index.notes.count - position)
            return made
        }
    }

}
