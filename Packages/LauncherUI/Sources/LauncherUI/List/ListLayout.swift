/// Where every header and row of a list sits, top-down from the top of the content.
///
/// Pure arithmetic over `ListContent` and `ListMetrics`, so it is tested without a window.
nonisolated struct ListLayout: Sendable, Equatable {
    /// What a line shows.
    enum Kind: Sendable, Equatable {
        case header(section: Int)
        /// `index` counts rows across all sections.
        case row(section: Int, row: Int, index: Int)
    }

    /// One header or row with its vertical extent.
    struct Line: Sendable, Equatable {
        var kind: Kind
        var y: Double
        var height: Double
        var maxY: Double { y + height }
    }

    private(set) var lines: [Line] = []
    /// For each row index, the index of its line.
    private(set) var rowLines: [Int] = []
    /// For each section that has rows, the row index of its first row.
    private(set) var sectionStarts: [Int] = []
    /// Height of everything, padding included.
    private(set) var contentHeight: Double = 0
    /// Height shown before the list scrolls: up to `maxVisibleRows` rows, capped at `maxHeight`.
    private(set) var viewportHeight: Double = 0
    let rowHeight: Double

    init(content: ListContent, metrics: ListMetrics, maxHeight: Double) {
        rowHeight = content.rowStyle == .twoLine ? metrics.twoLineRowHeight : metrics.rowHeight
        var y = metrics.verticalPadding
        var index = 0
        for (sectionIndex, section) in content.sections.enumerated() where !section.rows.isEmpty {
            if section.title != nil {
                lines.append(Line(kind: .header(section: sectionIndex), y: y, height: metrics.sectionHeaderHeight))
                y += metrics.sectionHeaderHeight
            }
            sectionStarts.append(index)
            for rowIndex in section.rows.indices {
                rowLines.append(lines.count)
                lines.append(
                    Line(kind: .row(section: sectionIndex, row: rowIndex, index: index), y: y, height: rowHeight))
                y += rowHeight
                index += 1
            }
        }
        guard index > 0 else { return }
        contentHeight = y + metrics.verticalPadding
        let lastVisible = lines[rowLines[min(metrics.maxVisibleRows, index) - 1]]
        viewportHeight = min(lastVisible.maxY + metrics.verticalPadding, maxHeight, contentHeight)
    }

    var rowCount: Int { rowLines.count }

    /// The largest scroll offset.
    var maxScrollOffset: Double { max(0, contentHeight - viewportHeight) }

    func rowLine(_ index: Int) -> Line? {
        rowLines.indices.contains(index) ? lines[rowLines[index]] : nil
    }

    /// Indices of the lines that overlap `minY..<maxY`.
    func lineIndices(overlapping minY: Double, _ maxY: Double) -> Range<Int> {
        let first = firstLine { $0.maxY > minY }
        let end = firstLine { $0.y >= maxY }
        return first..<max(first, end)
    }

    /// The rows that overlap `minY..<maxY`, counted across sections. Empty when none does.
    func rowIndices(overlapping minY: Double, _ maxY: Double) -> Range<Int> {
        var first: Int?
        var last = -1
        for line in lines[lineIndices(overlapping: minY, maxY)] {
            guard case .row(_, _, let index) = line.kind else { continue }
            if first == nil { first = index }
            last = index
        }
        guard let first else { return 0..<0 }
        return first..<(last + 1)
    }

    /// The row at content offset `y`, if a row is there.
    func rowIndex(atY y: Double) -> Int? {
        let index = firstLine { $0.maxY > y }
        guard lines.indices.contains(index), lines[index].y <= y,
            case .row(_, _, let row) = lines[index].kind
        else { return nil }
        return row
    }

    /// The first row of the section after the one holding `index`, or nil in the last section.
    func nextSectionStart(after index: Int) -> Int? {
        sectionStarts.first { $0 > index }
    }

    /// The first row of the section holding `index`, or of the section before when `index` is
    /// already a section's first row.
    func previousSectionStart(before index: Int) -> Int? {
        sectionStarts.last { $0 < index }
    }

    /// Binary search: the first line for which `isAfter` holds, given lines sorted by `y`.
    private func firstLine(where isAfter: (Line) -> Bool) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(lines[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
