import AppKit

/// Turns Markdown blocks into attributed text for the detail pane's TextKit 1 text view.
///
/// Code blocks and quotes are drawn by `NSTextBlock`s, which TextKit 1 draws as one box across the
/// paragraphs that share the same block object. The styler keeps one object per kind, so a block
/// rendered again during streaming compares equal to its earlier rendering and only the new text
/// is laid out.
@MainActor
struct MarkdownStyler {
    let style: ResolvedDetailStyle
    let metrics: DetailMetrics
    private let codeBox: NSTextBlock
    private let quoteBox: NSTextBlock
    private let ruleBox: NSTextBlock

    init(style: ResolvedDetailStyle, metrics: DetailMetrics, hairline: NSColor) {
        self.style = style
        self.metrics = metrics
        let padding = CGFloat(metrics.codeBlockPadding)
        // A block without a width collapses to its narrowest, one character per line.
        func fullWidth(_ box: NSTextBlock) -> NSTextBlock {
            box.setValue(100, type: .percentageValueType, for: .width)
            return box
        }
        codeBox = fullWidth(NSTextBlock())
        codeBox.backgroundColor = style.codeFill
        codeBox.setWidth(padding, type: .absoluteValueType, for: .padding)
        codeBox.setWidth(CGFloat(metrics.paragraphSpacing), type: .absoluteValueType, for: .margin, edge: .maxY)
        quoteBox = fullWidth(NSTextBlock())
        quoteBox.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        quoteBox.setBorderColor(
            style.codeFill.withAlphaComponent(min(1, style.codeFill.alphaComponent * 3)), for: .minX)
        quoteBox.setWidth(padding + 2, type: .absoluteValueType, for: .padding, edge: .minX)
        quoteBox.setWidth(CGFloat(metrics.paragraphSpacing), type: .absoluteValueType, for: .margin, edge: .maxY)
        ruleBox = fullWidth(NSTextBlock())
        ruleBox.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        ruleBox.setBorderColor(hairline, for: .minY)
        ruleBox.setWidth(CGFloat(metrics.paragraphSpacing), type: .absoluteValueType, for: .margin)
    }

    /// One block's text, without a trailing newline.
    func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let runs):
            let font = style.headingFonts[min(level, style.headingFonts.count) - 1]
            let paragraph = paragraphStyle()
            paragraph.paragraphSpacingBefore = CGFloat(metrics.paragraphSpacing) / 2
            paragraph.paragraphSpacing = CGFloat(metrics.paragraphSpacing) / 2
            return inline(runs, font: font, color: style.text, paragraph: paragraph)
        case .paragraph(let runs):
            return inline(runs, font: style.textFont, color: style.text, paragraph: paragraphStyle())
        case .listItem(let marker, let depth, let runs):
            let indent = CGFloat(metrics.listIndent)
            let paragraph = paragraphStyle()
            paragraph.firstLineHeadIndent = indent * CGFloat(depth)
            paragraph.headIndent = indent * CGFloat(depth + 1)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            paragraph.paragraphSpacing = CGFloat(metrics.paragraphSpacing) / 2
            let text = NSMutableAttributedString(
                string: marker + "\t",
                attributes: [.font: style.textFont, .foregroundColor: style.secondaryText, .paragraphStyle: paragraph])
            text.append(inline(runs, font: style.textFont, color: style.text, paragraph: paragraph))
            return text
        case .quote(let runs):
            let paragraph = paragraphStyle()
            paragraph.textBlocks = [quoteBox]
            paragraph.paragraphSpacing = 0
            return inline(runs, font: style.italicFont, color: style.secondaryText, paragraph: paragraph)
        case .code(let text):
            let paragraph = paragraphStyle()
            paragraph.textBlocks = [codeBox]
            paragraph.paragraphSpacing = 0
            // An empty block still needs one line, or its box collapses.
            return NSAttributedString(
                string: text.isEmpty ? " " : text,
                attributes: [.font: style.monospacedFont, .foregroundColor: style.text, .paragraphStyle: paragraph])
        case .rule:
            let paragraph = paragraphStyle()
            paragraph.textBlocks = [ruleBox]
            paragraph.paragraphSpacing = 0
            return NSAttributedString(
                string: " ",
                attributes: [.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: paragraph])
        }
    }

    /// Plain body text, in the body or monospaced font.
    func plain(_ text: String, monospaced: Bool) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: monospaced ? style.monospacedFont : style.textFont, .foregroundColor: style.text,
                .paragraphStyle: paragraphStyle(),
            ])
    }

    private func paragraphStyle() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(metrics.lineSpacing)
        paragraph.paragraphSpacing = CGFloat(metrics.paragraphSpacing)
        return paragraph
    }

    private func inline(_ runs: [MarkdownRun], font: NSFont, color: NSColor, paragraph: NSParagraphStyle)
        -> NSAttributedString
    {
        let text = NSMutableAttributedString()
        let manager = NSFontManager.shared
        for run in runs {
            var runFont = font
            if run.style.contains(.code) {
                runFont = NSFont.monospacedSystemFont(ofSize: style.monospacedFont.pointSize, weight: .regular)
            } else {
                if run.style.contains(.bold) { runFont = manager.convert(runFont, toHaveTrait: .boldFontMask) }
                if run.style.contains(.italic) { runFont = manager.convert(runFont, toHaveTrait: .italicFontMask) }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if run.style.contains(.code) { attributes[.backgroundColor] = style.codeFill }
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = style.link
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }
}
