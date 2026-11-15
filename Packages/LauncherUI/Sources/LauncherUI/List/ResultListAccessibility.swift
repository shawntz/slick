import AppKit

/// Accessibility for the result list. The list draws its rows itself, so it describes them with
/// `NSAccessibilityElement`s: a static text per section header and a button per row. They are
/// built only when a client asks and dropped when the content changes.
extension ResultListView {
    override public func accessibilityChildren() -> [Any]? {
        if let accessibilityCache { return accessibilityCache }
        var elements: [NSAccessibilityElement] = []
        var index = 0
        for section in content.sections where !section.rows.isEmpty {
            if let title = section.title {
                let header = NSAccessibilityElement()
                header.setAccessibilityRole(.staticText)
                header.setAccessibilityLabel(title)
                header.setAccessibilityParent(self)
                elements.append(header)
            }
            for row in section.rows {
                elements.append(ResultRowElement(index: index, row: row, list: self))
                index += 1
            }
        }
        accessibilityCache = elements
        return elements
    }

    override public func accessibilitySelectedChildren() -> [Any]? {
        guard let selectedRow else { return [] }
        let rows = accessibilityChildren()?.compactMap { $0 as? ResultRowElement } ?? []
        return rows.filter { $0.index == selectedRow }
    }

    /// Selects a row through accessibility and reports it as a user selection.
    func accessibilitySelect(_ index: Int) {
        select(index, animated: false)
        onSelect?(index)
    }

    /// Activates a row through accessibility.
    func accessibilityActivate(_ index: Int) {
        onActivate?(index)
    }
}

/// One row as accessibility clients see it. `NSAccessibilityElement` is not main-actor bound,
/// but AppKit calls it on the main thread, which the overrides assert.
nonisolated final class ResultRowElement: NSAccessibilityElement {
    let index: Int
    private weak var list: ResultListView?

    @MainActor init(index: Int, row: ListRow, list: ResultListView) {
        self.index = index
        self.list = list
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(list)
        let label = row.accessibilityLabel ?? (row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)")
        setAccessibilityLabel(label)
        let help = row.accessories.compactMap { accessory -> String? in
            switch accessory {
            case .text(let text), .tag(let text, _): text
            case .keycaps(let keys): keys.joined()
            case .icon: nil
            }
        }
        if !help.isEmpty { setAccessibilityHelp(help.joined(separator: ", ")) }
    }

    /// AppKit reads this with a bottom-left origin even though the list is flipped.
    override func accessibilityFrameInParentSpace() -> NSRect {
        let (list, index) = (list, index)
        return MainActor.assumeIsolated {
            guard let list, let rect = list.rowRect(index) else { return .zero }
            return CGRect(x: rect.minX, y: list.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let (list, index) = (list, index)
        return MainActor.assumeIsolated { list?.selectedRow == index }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        let (list, index) = (list, index)
        guard selected else { return }
        MainActor.assumeIsolated { list?.accessibilitySelect(index) }
    }

    override func accessibilityPerformPress() -> Bool {
        let (list, index) = (list, index)
        return MainActor.assumeIsolated {
            list?.accessibilityActivate(index)
            return list != nil
        }
    }
}
