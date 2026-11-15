import CoreGraphics

/// Where each row of a form goes: a right-aligned label column, the controls beside it, and a
/// message line under any field that has one. Pure, so it is tested without a window.
nonisolated struct FormLayout: Sendable, Equatable {
    /// One row's frames, in document coordinates.
    struct Row: Sendable, Equatable {
        var label: CGRect
        var control: CGRect
        /// The error or info line, or nil when the row has none.
        var message: CGRect?
        /// The whole row, label to message.
        var frame: CGRect
    }

    private(set) var rows: [Row] = []
    private(set) var contentHeight: Double = 0

    /// `controlHeights` gives each item's control height, in item order: a tag field grows with its
    /// lines and a description with its text.
    init(items: [FormItem], controlHeights: [Double], metrics: FormMetrics, width: Double) {
        let labelX = metrics.horizontalInset
        let controlX = labelX + metrics.labelWidth + metrics.labelGap
        let controlWidth = max(0, width - controlX - metrics.horizontalInset)
        var y = metrics.verticalPadding
        for (index, item) in items.enumerated() {
            if index > 0 { y += metrics.rowSpacing }
            let top = y
            let height = index < controlHeights.count ? controlHeights[index] : metrics.controlHeight
            let control: CGRect
            if case .separator = item.kind {
                control = CGRect(x: labelX, y: y, width: width - labelX * 2, height: metrics.separatorHeight)
            } else {
                control = CGRect(x: controlX, y: y, width: controlWidth, height: height)
            }
            // The label lines up with the first line of the control.
            let label = CGRect(x: labelX, y: y, width: metrics.labelWidth, height: min(height, metrics.controlHeight))
            y = control.maxY
            var message: CGRect?
            if item.message != nil {
                y += metrics.messageGap
                message = CGRect(x: controlX, y: y, width: controlWidth, height: metrics.messageHeight)
                y += metrics.messageHeight
            }
            rows.append(
                Row(
                    label: label, control: control, message: message,
                    frame: CGRect(x: 0, y: top, width: width, height: y - top)))
        }
        contentHeight = items.isEmpty ? 0 : y + metrics.verticalPadding
    }

    /// The control height a kind has before its contents are known.
    static func defaultControlHeight(_ kind: FormItem.Kind, metrics: FormMetrics) -> Double {
        switch kind {
        case .multiline: metrics.multilineHeight
        case .separator: metrics.separatorHeight
        default: metrics.controlHeight
        }
    }
}

/// Lays tags out in lines inside a tag field, followed by the text field for the next tag.
nonisolated enum TagFlow {
    /// Frames for capsules of `widths` and for the input field, which needs at least `fieldWidth`,
    /// in a field of `width`. Each line is `lineHeight` tall with capsules of `tagHeight` centred.
    static func layout(
        widths: [Double], fieldWidth: Double, width: Double, lineHeight: Double, tagHeight: Double, spacing: Double,
        padding: Double
    ) -> (tags: [CGRect], field: CGRect, lines: Int) {
        var tags: [CGRect] = []
        var x = padding
        var line = 0
        let usable = max(1, width - padding * 2)
        func top(_ line: Int) -> Double { Double(line) * lineHeight + (lineHeight - tagHeight) / 2 }
        for tagWidth in widths {
            let clamped = min(tagWidth, usable)
            if x > padding, x + clamped > width - padding {
                line += 1
                x = padding
            }
            tags.append(CGRect(x: x, y: top(line), width: clamped, height: tagHeight))
            x += clamped + spacing
        }
        if x > padding, x + fieldWidth > width - padding {
            line += 1
            x = padding
        }
        let field = CGRect(
            x: x, y: Double(line) * lineHeight, width: max(fieldWidth, width - padding - x), height: lineHeight)
        return (tags, field, line + 1)
    }
}
