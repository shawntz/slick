import CoreGraphics

/// Where every section header and cell of a grid sits, top-down from the top of the content.
///
/// It stores one block per section, not one frame per cell, so a 3,000-cell grid lays out in
/// microseconds: a cell's frame is arithmetic on its block. Pure, so it is tested without a window.
nonisolated struct GridLayout: Sendable, Equatable {
    /// One non-empty section: its optional header and its rows of cells.
    struct Block: Sendable, Equatable {
        var section: Int
        /// Top of the header, or nil for a section without one.
        var headerY: Double?
        /// Top of the first row of cells.
        var firstRowY: Double
        /// Index of the first cell, counted across sections.
        var start: Int
        var count: Int
        var rows: Int
        var end: Int { start + count }
    }

    let columns: Int
    /// Width of a cell and its tile.
    let cellWidth: Double
    let tileHeight: Double
    /// Height of a cell: the tile plus its title lines.
    let cellHeight: Double
    let spacing: Double
    /// Left edge of the first column.
    let originX: Double
    let headerHeight: Double
    private(set) var blocks: [Block] = []
    private(set) var cellCount = 0
    private(set) var contentHeight: Double = 0
    /// Height shown before the grid scrolls, at most `maxHeight`.
    private(set) var viewportHeight: Double = 0

    init(content: GridContent, metrics: GridMetrics, list: ListMetrics, width: Double, maxHeight: Double) {
        let columns = content.columns.count(in: metrics)
        self.columns = columns
        spacing = metrics.spacing
        let usable = width - metrics.horizontalInset * 2 - spacing * Double(columns - 1)
        cellWidth = max(1, (usable / Double(columns)).rounded(.down))
        // Whatever rounding left over is split between the two sides, so the grid stays centred.
        originX = ((width - cellWidth * Double(columns) - spacing * Double(columns - 1)) / 2).rounded()
        tileHeight = (cellWidth / max(0.1, content.aspectRatio)).rounded()
        var cellHeight = tileHeight
        if content.showsTitles {
            cellHeight += metrics.titleGap + metrics.titleHeight
            if content.sections.contains(where: { $0.cells.contains { !$0.subtitle.isEmpty } }) {
                cellHeight += metrics.subtitleHeight
            }
        }
        self.cellHeight = cellHeight
        headerHeight = list.sectionHeaderHeight

        var y = metrics.verticalPadding
        var start = 0
        for (index, section) in content.sections.enumerated() where !section.cells.isEmpty {
            if !blocks.isEmpty { y += spacing }
            var headerY: Double?
            if section.hasHeader {
                headerY = y
                y += headerHeight
            }
            let rows = (section.cells.count + columns - 1) / columns
            blocks.append(
                Block(
                    section: index, headerY: headerY, firstRowY: y, start: start, count: section.cells.count,
                    rows: rows))
            y += Double(rows) * cellHeight + Double(rows - 1) * spacing
            start += section.cells.count
        }
        cellCount = start
        guard start > 0 else { return }
        contentHeight = y + metrics.verticalPadding
        viewportHeight =
            contentHeight <= maxHeight
            ? contentHeight : wholeRowsHeight(within: maxHeight, padding: metrics.verticalPadding)
    }

    /// The height that shows only whole rows: down to the last row whose bottom fits in `limit`
    /// with padding under it, as the list shows only whole rows.
    private func wholeRowsHeight(within limit: Double, padding: Double) -> Double {
        var bottom = 0.0
        for block in blocks {
            let room = limit - padding - block.firstRowY - cellHeight
            guard room >= 0 else { break }
            let rows = min(block.rows, Int((room / rowStride).rounded(.down)) + 1)
            bottom = block.firstRowY + Double(rows - 1) * rowStride + cellHeight
            if rows < block.rows { break }
        }
        return bottom > 0 ? min(limit, bottom + padding) : limit
    }

    /// The largest scroll offset.
    var maxScrollOffset: Double { max(0, contentHeight - viewportHeight) }

    private var rowStride: Double { cellHeight + spacing }

    /// The block holding cell `index`.
    func blockIndex(of index: Int) -> Int? {
        guard index >= 0, index < cellCount else { return nil }
        var low = 0
        var high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blocks[mid].start <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The section and the position in it of cell `index`.
    func location(of index: Int) -> (section: Int, item: Int)? {
        guard let block = blockIndex(of: index).map({ blocks[$0] }) else { return nil }
        return (block.section, index - block.start)
    }

    /// The frame of cell `index`: its tile and the title lines under it.
    func cellFrame(_ index: Int) -> CGRect? {
        guard let block = blockIndex(of: index).map({ blocks[$0] }) else { return nil }
        let local = index - block.start
        let row = local / columns
        let column = local % columns
        return CGRect(
            x: originX + Double(column) * (cellWidth + spacing), y: block.firstRowY + Double(row) * rowStride,
            width: cellWidth, height: cellHeight)
    }

    /// The frame of cell `index`'s tile.
    func tileFrame(_ index: Int) -> CGRect? {
        cellFrame(index).map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: tileHeight) }
    }

    /// The cell under a point in content coordinates, if one is there.
    func cellIndex(atX x: Double, y: Double) -> Int? {
        let column = Int(((x - originX) / (cellWidth + spacing)).rounded(.down))
        guard column >= 0, column < columns, x - originX - Double(column) * (cellWidth + spacing) < cellWidth else {
            return nil
        }
        for block in blocks {
            let offset = y - block.firstRowY
            guard offset >= 0 else { continue }
            let row = Int((offset / rowStride).rounded(.down))
            guard row < block.rows else { continue }
            guard offset - Double(row) * rowStride < cellHeight else { return nil }
            let index = block.start + row * columns + column
            return index < block.end ? index : nil
        }
        return nil
    }

    /// The cells that overlap `minY..<maxY`, in order.
    func cells(overlapping minY: Double, _ maxY: Double) -> [Int] {
        var result: [Int] = []
        for block in blocks {
            let blockBottom = block.firstRowY + Double(block.rows) * rowStride - spacing
            guard blockBottom > minY, block.firstRowY < maxY else { continue }
            let firstRow = max(0, Int(((minY - block.firstRowY) / rowStride).rounded(.down)))
            // maxY is exclusive: a row that starts exactly at maxY is not visible.
            let lastRow = min(block.rows - 1, Int(((maxY - block.firstRowY) / rowStride).rounded(.up)) - 1)
            guard firstRow <= lastRow else { continue }
            let from = block.start + firstRow * columns
            let to = min(block.end, block.start + (lastRow + 1) * columns)
            if from < to { result.append(contentsOf: from..<to) }
        }
        return result
    }

    /// The headers that overlap `minY..<maxY`: their section and top.
    func headers(overlapping minY: Double, _ maxY: Double) -> [(section: Int, y: Double)] {
        blocks.compactMap { block in
            guard let y = block.headerY, y + headerHeight > minY, y < maxY else { return nil }
            return (block.section, y)
        }
    }

    /// The cell a move from `index` lands on, or nil at an edge. Left and right step through the
    /// cells in order; up and down keep the column, crossing into the next or previous section and
    /// clamping to a shorter last row.
    func target(from index: Int, moving direction: GridDirection) -> Int? {
        guard let blockIndex = blockIndex(of: index) else { return nil }
        let block = blocks[blockIndex]
        let local = index - block.start
        let row = local / columns
        let column = local % columns
        switch direction {
        case .left:
            return index > 0 ? index - 1 : nil
        case .right:
            return index + 1 < cellCount ? index + 1 : nil
        case .down:
            if row + 1 < block.rows { return block.start + min((row + 1) * columns + column, block.count - 1) }
            guard blockIndex + 1 < blocks.count else { return nil }
            let next = blocks[blockIndex + 1]
            return next.start + min(column, next.count - 1)
        case .up:
            if row > 0 { return block.start + (row - 1) * columns + column }
            guard blockIndex > 0 else { return nil }
            let previous = blocks[blockIndex - 1]
            return previous.start + min((previous.rows - 1) * columns + column, previous.count - 1)
        }
    }

    /// The first cell of the section after the one holding `index`.
    func nextSectionStart(after index: Int) -> Int? {
        blocks.first { $0.start > index }?.start
    }

    /// The first cell of the section holding `index`, or of the section before when `index`
    /// already starts its section.
    func previousSectionStart(before index: Int) -> Int? {
        blocks.last { $0.start < index }?.start
    }
}
