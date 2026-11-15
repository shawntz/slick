import AppKit

/// Accessibility for the grid: a static text per section header and a button per cell, built
/// only when a client asks and dropped when the content changes.
extension GridView {
    override public func accessibilityChildren() -> [Any]? {
        if let accessibilityCache { return accessibilityCache }
        var elements: [NSAccessibilityElement] = []
        var index = 0
        for section in content.sections where !section.cells.isEmpty {
            if let label = SectionHeader.spoken(title: section.title, count: section.count) {
                let header = NSAccessibilityElement()
                header.setAccessibilityRole(.staticText)
                header.setAccessibilityLabel(label)
                header.setAccessibilityParent(self)
                elements.append(header)
            }
            for cell in section.cells {
                elements.append(GridCellElement(index: index, cell: cell, grid: self))
                index += 1
            }
        }
        accessibilityCache = elements
        return elements
    }

    override public func accessibilitySelectedChildren() -> [Any]? {
        guard let selectedIndex else { return [] }
        let cells = accessibilityChildren()?.compactMap { $0 as? GridCellElement } ?? []
        return cells.filter { $0.index == selectedIndex }
    }

    func accessibilitySelect(_ index: Int) {
        select(index, animated: false)
        onSelect?(index)
    }

    func accessibilityActivate(_ index: Int) {
        onActivate?(index)
    }
}

/// One cell as accessibility clients see it. AppKit calls it on the main thread.
nonisolated final class GridCellElement: NSAccessibilityElement {
    let index: Int
    private weak var grid: GridView?

    @MainActor init(index: Int, cell: GridCell, grid: GridView) {
        self.index = index
        self.grid = grid
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(grid)
        var label = cell.accessibilityLabel ?? cell.title
        if label.isEmpty, case .glyph(let glyph) = cell.content { label = glyph }
        setAccessibilityLabel(
            cell.subtitle.isEmpty || cell.accessibilityLabel != nil ? label : "\(label), \(cell.subtitle)")
    }

    /// AppKit reads this with a bottom-left origin even though the grid is flipped.
    override func accessibilityFrameInParentSpace() -> NSRect {
        let (grid, index) = (grid, index)
        return MainActor.assumeIsolated {
            guard let grid, let rect = grid.cellRect(index) else { return .zero }
            return CGRect(x: rect.minX, y: grid.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let (grid, index) = (grid, index)
        return MainActor.assumeIsolated { grid?.selectedIndex == index }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        let (grid, index) = (grid, index)
        guard selected else { return }
        MainActor.assumeIsolated { grid?.accessibilitySelect(index) }
    }

    override func accessibilityPerformPress() -> Bool {
        let (grid, index) = (grid, index)
        return MainActor.assumeIsolated {
            grid?.accessibilityActivate(index)
            return grid != nil
        }
    }
}
