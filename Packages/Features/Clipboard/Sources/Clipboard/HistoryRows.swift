import Foundation
import Kit

/// Turns history items into rows and sections. Pure, so it runs off the main thread.
nonisolated enum HistoryRows {
    /// The namespace of history rows and of the suggestion's row: `clipboard:<item key>`.
    static let namespace = "clipboard"
    /// The ID of the Pinned section.
    static let pinnedSectionID = "pinned"
    /// Characters a title shows at most.
    static let titleLength = 200

    static func id(_ key: ItemKey) -> ItemID {
        ItemID(namespace, key.hex)
    }

    /// What a row carries for its actions. Rows made by this feature always carry it; for any
    /// other row the key is read from the ID and the kind is unknown.
    static func payload(of row: Row) -> RowPayload? {
        if let payload = try? row.payload?.decode(RowPayload.self) { return payload }
        return nil
    }

    /// The key behind one of this feature's rows.
    static func key(of row: Row) -> ItemKey? {
        guard row.id.namespace == namespace else { return nil }
        return ItemKey(hex: row.id.key)
    }

    /// The pinned items, then the rest by day, newest first. Section IDs are stable, `pinned` and
    /// `day-YYYY-MM-DD`, so the next page's rows join the section they belong to.
    @concurrent static func sections(
        for page: HistoryPage, query: SearchQuery, days: DaySections, calendar: Calendar,
        workspace: any WorkspaceService
    ) async -> [ListSection] {
        var names: [String: String?] = [:]
        func appName(_ bundleID: String) -> String? {
            if let known = names[bundleID] { return known }
            let name = workspace.application(bundleID: bundleID)?.name
            names[bundleID] = name
            return name
        }
        var sections: [ListSection] = []
        if !page.pinned.isEmpty {
            let rows = page.pinned.map { row(for: $0, query: query, appName: $0.source.flatMap(appName)) }
            sections.append(ListSection(Strings.List.pinnedSection, id: pinnedSectionID, rows: rows))
        }
        var used = Set<String>()
        for item in page.items {
            let row = row(for: item, query: query, appName: item.source.flatMap(appName))
            let id = dayID(for: item.copied, calendar: calendar)
            // A clock set back can put an older day after a newer one; such rows join the section
            // before them, so no two sections share an ID.
            if let last = sections.indices.last, sections[last].id == id || used.contains(id) {
                sections[last].rows.append(row)
            } else {
                used.insert(id)
                sections.append(ListSection(days.title(for: item.copied), id: id, rows: [row]))
            }
        }
        return sections
    }

    /// One item's row.
    static func row(for item: ItemSummary, query: SearchQuery, appName: String?) -> Row {
        let title = title(for: item)
        var accessories: [Accessory] = []
        if let source = item.source {
            accessories.append(.icon(.app(bundleID: source), tooltip: appName ?? source))
        }
        accessories.append(.date(item.copied))
        return Row(
            id: id(item.key),
            title: title,
            icon: icon(for: item),
            accessories: accessories,
            payload: Payload(RowPayload(key: item.key, kind: item.kind, isPinned: item.isPinned)),
            quickLookURL: item.kind == .image ? item.imageURL : item.fileURLs.first,
            titleHighlights: highlights(of: query, in: title),
            memory: .never,
            represents: represents(item))
    }

    /// The first line with text, trimmed, for text; the link or color; the file name or a count;
    /// the image's size.
    static func title(for item: ItemSummary) -> String {
        switch item.kind {
        case .image:
            if let width = item.pixelWidth, let height = item.pixelHeight {
                return Strings.Rows.image(width: width, height: height)
            }
            return Strings.Rows.image
        case .files:
            let files = HistoryStore.fileURLs(item.shortText ?? item.preview ?? "")
            if files.count == 1 { return files[0].lastPathComponent }
            return item.shortText == nil ? Strings.Rows.manyFiles : Strings.Rows.files(files.count)
        case .text, .richText, .link, .color:
            let text = item.preview ?? ""
            let line = text.split(whereSeparator: \.isNewline).first { $0.contains(where: isVisible) }
            guard let line else { return Strings.Rows.emptyText }
            return String(line.trimmingCharacters(in: .whitespaces).prefix(titleLength))
        }
    }

    /// False for white space and for characters that draw nothing, such as a zero-width space, so a
    /// row is never titled with text no one can see.
    static func isVisible(_ character: Character) -> Bool {
        !character.isWhitespace && !character.unicodeScalars.allSatisfy(\.properties.isDefaultIgnorableCodePoint)
    }

    static func icon(for item: ItemSummary) -> Icon {
        switch item.kind {
        case .color:
            (item.shortText ?? item.preview).flatMap { KitColor(hex: $0.trimmingCharacters(in: .whitespaces)) }
                .map(Icon.color) ?? .symbol(item.kind.symbol)
        case .image:
            item.thumbnailURL.map { .image(path: $0.path) } ?? .symbol(item.kind.symbol)
        case .files:
            item.fileURLs.first.map { .file(path: $0.path) } ?? .symbol(item.kind.symbol)
        case .text, .richText, .link:
            .symbol(item.kind.symbol)
        }
    }

    /// What the row stands for, so other features' actions for text, links and files apply to it.
    /// Long text is left out: the row carries only its beginning.
    static func represents(_ item: ItemSummary) -> Selection? {
        switch item.kind {
        case .link: item.link.map(Selection.url)
        case .files: item.shortText == nil ? nil : .files(item.fileURLs)
        case .text, .richText, .color: item.shortText.map(Selection.text)
        case .image: nil
        }
    }

    /// Where each searched word appears in the title, ignoring case and accents, in UTF-16 offsets.
    static func highlights(of query: SearchQuery, in title: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for word in query.words {
            var searchStart = title.startIndex
            while let found = title.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<title.endIndex)
            {
                let start = title.utf16.distance(from: title.startIndex, to: found.lowerBound)
                ranges.append(start..<(start + title[found].utf16.count))
                searchStart = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `day-YYYY-MM-DD` in the clock's calendar.
    static func dayID(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "day-\(parts.year ?? 0)-\(padded(parts.month))-\(padded(parts.day))"
    }
}
