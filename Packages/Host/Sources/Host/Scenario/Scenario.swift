import Foundation

/// A scripted run of the panel, read from a JSON file. The format is documented in
/// docs/SCENARIOS.md.
///
/// ```json
/// {
///   "name": "Clipboard history opens",
///   "timeLimit": 20,
///   "steps": [
///     { "summon": true },
///     { "type": "clip" },
///     { "expect": { "selection": "Clipboard History" } },
///     { "press": "return" },
///     { "waitUntilIdle": 2 },
///     { "expect": { "title": "Clipboard History", "rowCount": 7 } },
///     { "capture": "history" },
///     { "dismiss": true }
///   ]
/// }
/// ```
public struct Scenario: Sendable, Decodable, Equatable {
    /// The longest any scenario may run, whatever its file asks.
    public static let maximumTimeLimit: Double = 120

    public var name: String
    /// Seconds the whole run may take before it fails. Default 30, at most ``maximumTimeLimit``.
    public var timeLimit: Double
    public var steps: [ScenarioStep]

    public init(name: String, timeLimit: Double = 30, steps: [ScenarioStep]) {
        self.name = name
        self.timeLimit = min(timeLimit, Self.maximumTimeLimit)
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case name, timeLimit, steps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        timeLimit = min(try container.decodeIfPresent(Double.self, forKey: .timeLimit) ?? 30, Self.maximumTimeLimit)
        steps = try container.decode([ScenarioStep].self, forKey: .steps)
    }

    /// Reads a scenario file.
    public static func load(_ url: URL) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    }
}

/// One step. In the file each step is an object with exactly one key, the step's name.
public enum ScenarioStep: Sendable, Decodable, Equatable {
    /// Shows the panel without key status.
    case summon
    /// Types text at the end of the focused field, one character at a time.
    case type(String)
    /// Presses a key combination such as `down`, `return`, `cmd+k` or `shift+cmd+return`.
    case press(String)
    /// Waits until nothing loads, streams, runs or animates, for at most this many seconds.
    case waitUntilIdle(Double)
    /// Waits this many seconds.
    case wait(Double)
    /// Checks what the panel shows.
    case expect(ScenarioExpectation)
    /// Writes a PNG of the panel named after this text. With `key` the panel takes key status for
    /// the capture only.
    case capture(name: String, key: Bool)
    /// Sets a form field's value: text, a checkbox's `true` or `false`, or a dropdown option's ID.
    case fill(field: String, value: String)
    /// Hides the panel.
    case dismiss
    /// Starts a clip. The steps after it play at a person's pace, with the panel key over a
    /// wallpaper, until `stopRecording`. Only a build with recording can do it.
    case record(ScenarioRecording)
    /// Ends the clip and writes its files.
    case stopRecording(ScenarioClipOutput)
    /// During a clip, writes a PNG named after this text of the clip's whole recorded area: the
    /// wallpaper and every window of this app over it, such as a settings window, without loss.
    case still(String)

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Capture: Decodable {
        var name: String
        var key: Bool?
    }

    private struct Fill: Decodable {
        var field: String
        var value: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "a step has exactly one key"))
        }
        switch key.stringValue {
        case "summon": self = .summon
        case "dismiss": self = .dismiss
        case "type": self = .type(try container.decode(String.self, forKey: key))
        case "press": self = .press(try container.decode(String.self, forKey: key))
        case "waitUntilIdle": self = .waitUntilIdle(try container.decode(Double.self, forKey: key))
        case "wait": self = .wait(try container.decode(Double.self, forKey: key))
        case "expect": self = .expect(try container.decode(ScenarioExpectation.self, forKey: key))
        case "fill":
            let fill = try container.decode(Fill.self, forKey: key)
            self = .fill(field: fill.field, value: fill.value)
        case "capture":
            if let name = try? container.decode(String.self, forKey: key) {
                self = .capture(name: name, key: false)
            } else {
                let capture = try container.decode(Capture.self, forKey: key)
                self = .capture(name: capture.name, key: capture.key ?? false)
            }
        case "record": self = .record(try container.decode(ScenarioRecording.self, forKey: key))
        case "stopRecording":
            if let flag = try? container.decode(Bool.self, forKey: key) {
                guard flag else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "stopRecording takes true or an object")
                    )
                }
                self = .stopRecording(ScenarioClipOutput())
            } else {
                self = .stopRecording(try container.decode(ScenarioClipOutput.self, forKey: key))
            }
        case "still":
            let name = try container.decode(String.self, forKey: key)
            guard ScenarioRecording.isFileName(name) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "a still's name uses letters, digits, - and _ only"))
            }
            self = .still(name)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown step \"\(key.stringValue)\""))
        }
    }

    /// The step's name, as the file spells it.
    public var name: String {
        switch self {
        case .summon: "summon"
        case .type: "type"
        case .press: "press"
        case .waitUntilIdle: "waitUntilIdle"
        case .wait: "wait"
        case .expect: "expect"
        case .capture: "capture"
        case .fill: "fill"
        case .dismiss: "dismiss"
        case .record: "record"
        case .stopRecording: "stopRecording"
        case .still: "still"
        }
    }
}

/// What an `expect` step checks. Every key is optional; each one present must hold.
public struct ScenarioExpectation: Sendable, Decodable, Equatable {
    /// The titles of every shown row or cell, in order.
    public var rows: [String]?
    /// Titles that must be among the shown rows or cells.
    public var rowsInclude: [String]?
    public var rowCount: Int?
    /// The selected row's or cell's title; empty when nothing is selected.
    public var selection: String?
    /// The toast's text, as the action bar shows it.
    public var toast: String?
    /// True when no toast may show.
    public var noToast: Bool?
    /// The top page's title; empty for root search.
    public var title: String?
    /// The ghost completion after the typed text.
    public var ghost: String?
    /// The search field's text.
    public var query: String?
    /// The top page's kind: root, list, grid, detail, form, quickLook or other.
    public var page: String?
    /// Text the detail pane or detail page must contain.
    public var detailIncludes: String?
    /// The action panel's entry titles, in order. The panel must be open.
    public var actions: [String]?
    /// True when the panel must be on screen, false when it must be hidden.
    public var visible: Bool?
    /// The IDs of the form fields that show an error, in any order. Empty for none.
    public var fieldErrors: [String]?
    /// The title of the confirmation or permission card waiting for an answer. Empty for none.
    public var card: String?

    public init(
        rows: [String]? = nil, rowsInclude: [String]? = nil, rowCount: Int? = nil, selection: String? = nil,
        toast: String? = nil, noToast: Bool? = nil, title: String? = nil, ghost: String? = nil, query: String? = nil,
        page: String? = nil, detailIncludes: String? = nil, actions: [String]? = nil, visible: Bool? = nil,
        fieldErrors: [String]? = nil, card: String? = nil
    ) {
        self.rows = rows
        self.rowsInclude = rowsInclude
        self.rowCount = rowCount
        self.selection = selection
        self.toast = toast
        self.noToast = noToast
        self.title = title
        self.ghost = ghost
        self.query = query
        self.page = page
        self.detailIncludes = detailIncludes
        self.actions = actions
        self.visible = visible
        self.fieldErrors = fieldErrors
        self.card = card
    }
}
