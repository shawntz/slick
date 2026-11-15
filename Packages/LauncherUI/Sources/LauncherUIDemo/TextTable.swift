import Foundation

/// A Markdown table for the console.
struct TextTable {
    private let headers: [String]
    private var rows: [[String]] = []

    init(_ headers: [String]) { self.headers = headers }

    mutating func add(_ cells: [String]) { rows.append(cells) }

    func render() -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            "| "
                + cells.enumerated().map {
                    $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0)
                }
                .joined(separator: " | ") + " |"
        }
        let rule = "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|"
        return ([line(headers), rule] + rows.map(line)).joined(separator: "\n")
    }
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func format(_ value: Double, _ digits: Int = 2) -> String {
    value.isFinite ? String(format: "%.\(digits)f", value) : "-"
}

@MainActor
func pause(ms: Double) async {
    try? await Task.sleep(for: .microseconds(Int(ms * 1000)))
}
