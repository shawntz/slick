import Host
import Kit

/// App checks of what the top page holds beyond what Host's expectations read: the selected row's
/// subtitle, the labels of a detail page's metadata, and the option a list's dropdown shows.
extension ScenarioMode {
    /// The problems with the step's `selectedSubtitle`, `detailMetadata` and `filter` checks.
    static func panelChecks(_ step: AppStep, panel: PanelController?) -> [String] {
        guard step.selectedSubtitle != nil || step.detailMetadata != nil || step.filter != nil else { return [] }
        guard let panel else { return ["the panel checks need the panel"] }
        var problems: [String] = []
        if let expected = step.selectedSubtitle {
            let row: Row? =
                switch panel.top {
                case let page as RootPageController: page.selectedRow?.row
                case let page as ListPageController: page.selectedRow
                default: nil
                }
            let subtitle = row?.subtitle ?? ""
            if subtitle != expected {
                problems.append("the selected row's subtitle was \"\(subtitle)\", expected \"\(expected)\"")
            }
        }
        if let expected = step.detailMetadata {
            if let page = panel.top as? DetailPageController {
                let shown = metadataValues(page.detail.metadata)
                for (label, value) in expected.sorted(by: { $0.key < $1.key }) where shown[label] != value {
                    problems.append("the detail's \(label) was \(shown[label] ?? "missing"), expected \(value)")
                }
            } else {
                problems.append("detailMetadata needs a detail page on top, not \(panel.topPageKind)")
            }
        }
        if let expected = step.filter {
            if let page = panel.top as? ListPageController, let dropdown = page.dropdown {
                let shown = dropdown.options.first { $0.id == page.filterID }?.title ?? ""
                if shown != expected { problems.append("the dropdown showed \"\(shown)\", expected \"\(expected)\"") }
            } else {
                problems.append("filter needs a list with a dropdown on top")
            }
        }
        return problems
    }

    /// Each metadata label with the text it shows: a value, a link's text, or tags joined by commas.
    /// Dates, colors and separators show no text a file can name.
    static func metadataValues(_ items: [MetadataItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            switch item {
            case .label(let label, let value, _): values[label] = value
            case .link(let label, let text, _): values[label] = text
            case .tags(let label, let tags): values[label] = tags.map(\.text).joined(separator: ", ")
            case .color, .date, .separator: break
            }
        }
        return values
    }
}
