import Foundation
import Kit

/// One metadata comment, such as `# @raycast.title Say Hello` on line 3.
nonisolated struct MetadataLine: Hashable, Sendable {
    /// `@raycast.` or the feature's own prefix.
    var prefix: String
    /// Empty when the line has a prefix but no key.
    var key: String
    var value: String
    /// Counting from 1.
    var line: Int
}

/// What a script's header says, and what is wrong with it.
nonisolated struct ParsedHeader: Hashable, Sendable {
    /// Nil when the header has an error.
    var metadata: ScriptMetadata?
    var problems: [ScriptProblem]
    /// False for a file with no metadata lines at all, such as a helper or a README. Such a file is
    /// not a script command and is skipped without a problem.
    var isScript: Bool
}

/// Reads the metadata comments of a script.
///
/// A metadata line is a comment, `#`, `//` or `--`, followed by a prefix, a key and a value:
/// `# @raycast.title Say Hello`. Two prefixes are read: `@raycast.`, so scripts from the public
/// collections work unchanged, and the feature's own, `@` plus the URL scheme plus `.`. The format
/// is documented at https://github.com/raycast/script-commands in README.md, ARGUMENTS.md and
/// OUTPUTMODES.md.
///
/// The parse is strict. A missing or unknown schema version, title or mode, an argument that is not
/// valid JSON, or a refresh time an inline script cannot use is an error, and the script does not
/// become a command. A key that is unknown, set twice, or has a value that is ignored is a warning.
nonisolated enum HeaderParser {
    static let publicPrefix = "@raycast."
    static let ownPrefix = "@" + Brand.urlScheme + "."
    static let commentMarkers = ["#", "//", "--"]

    /// Keys of the public format.
    static let publicKeys: Set<String> = [
        "schemaVersion", "title", "mode", "packageName", "icon", "iconDark", "currentDirectoryPath",
        "needsConfirmation", "refreshTime", "argument1", "argument2", "argument3", "author", "authorURL",
        "description", "platform",
    ]
    /// Keys read only under the feature's own prefix.
    static let ownKeys: Set<String> = ["filterAction"]

    /// The shortest refresh the format allows.
    static let minimumRefresh = Duration.seconds(10)

    // MARK: - Lines

    /// Every metadata line in the header, in order.
    static func lines(in header: String) -> [MetadataLine] {
        var result: [MetadataLine] = []
        var number = 0
        for raw in header.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            // A byte order mark may start the first line.
            var line = Substring(raw).drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
            guard let marker = commentMarkers.first(where: { line.hasPrefix($0) }) else { continue }
            line = line.dropFirst(marker.count).drop { $0 == " " || $0 == "\t" }
            guard let prefix = [ownPrefix, publicPrefix].first(where: { line.hasPrefix($0) }) else { continue }
            line = line.dropFirst(prefix.count)
            let key = line.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let rest = line.dropFirst(key.count)
            if let next = rest.first, next != " ", next != "\t", next != "\r" {
                result.append(MetadataLine(prefix: prefix, key: "", value: "", line: number))
                continue
            }
            result.append(MetadataLine(prefix: prefix, key: String(key), value: rest.trimmed, line: number))
        }
        return result
    }

    // MARK: - Parsing

    static func parse(_ header: String) -> ParsedHeader {
        let all = lines(in: header)
        guard !all.isEmpty else { return ParsedHeader(metadata: nil, problems: [], isScript: false) }
        var reader = Reader(lines: all)
        let metadata = reader.read()
        let hasError = reader.problems.contains { $0.severity == .error }
        return ParsedHeader(metadata: hasError ? nil : metadata, problems: reader.problems, isScript: true)
    }

    /// Reads one header, collecting problems as it goes.
    private struct Reader {
        var fields: [String: MetadataLine] = [:]
        var problems: [ScriptProblem] = []
        /// The prefix to suggest in messages: the one the file uses.
        let prefix: String

        init(lines: [MetadataLine]) {
            prefix = lines.contains { $0.prefix == HeaderParser.ownPrefix } ? HeaderParser.ownPrefix : publicPrefix
            for line in lines {
                if line.key.isEmpty {
                    problems.append(.warning(Strings.Problem.malformed(), line: line.line))
                } else if !publicKeys.contains(line.key) && !ownKeys.contains(line.key) {
                    problems.append(.warning(Strings.Problem.unknownKey(line.key), line: line.line))
                } else if ownKeys.contains(line.key) && line.prefix != HeaderParser.ownPrefix {
                    problems.append(
                        .warning(
                            Strings.Problem.ownPrefixOnly(line.key, prefix: HeaderParser.ownPrefix), line: line.line))
                } else if fields[line.key] != nil {
                    problems.append(.warning(Strings.Problem.duplicate(line.key), line: line.line))
                } else if line.value.isEmpty {
                    if !["schemaVersion", "title", "mode"].contains(line.key) {
                        problems.append(.warning(Strings.Problem.emptyValue(line.key), line: line.line))
                    }
                } else {
                    fields[line.key] = line
                }
            }
        }

        mutating func read() -> ScriptMetadata {
            var metadata = ScriptMetadata(schemaVersion: 1, title: "", mode: .compact)
            if let line = required("schemaVersion") {
                if line.value != "1" {
                    problems.append(.error(Strings.Problem.schemaVersion(line.value), line: line.line))
                }
            }
            if let line = required("title") {
                metadata.title = line.value
            }
            if let line = required("mode") {
                if let mode = ScriptMode(rawValue: line.value) {
                    metadata.mode = mode
                } else {
                    problems.append(.error(Strings.Problem.mode(line.value), line: line.line))
                }
            }
            if let line = fields["platform"] {
                let platforms = line.value.lowercased().split { $0 == "," || $0 == " " }
                if !platforms.contains("macos") {
                    problems.append(.error(Strings.Problem.platform(line.value), line: line.line))
                }
            }
            metadata.packageName = fields["packageName"]?.value
            metadata.description = fields["description"]?.value
            metadata.author = fields["author"]?.value
            metadata.currentDirectoryPath = fields["currentDirectoryPath"]?.value
            metadata.icon = icon("icon")
            metadata.iconDark = icon("iconDark")
            if let line = fields["needsConfirmation"] {
                // The author asked for something here, so any value but false asks first.
                switch line.value.lowercased() {
                case "false": metadata.needsConfirmation = false
                case "true": metadata.needsConfirmation = true
                default:
                    metadata.needsConfirmation = true
                    problems.append(.warning(Strings.Problem.confirmation(line.value), line: line.line))
                }
            }
            metadata.refreshTime = refreshTime(mode: metadata.mode)
            metadata.filterAction = filterAction(mode: metadata.mode)
            metadata.arguments = arguments()
            if metadata.mode == .list && !metadata.arguments.isEmpty {
                let line = fields["argument1"]?.line ?? fields["argument2"]?.line ?? fields["argument3"]?.line
                problems.append(.warning(Strings.Problem.argumentsInList, line: line))
                metadata.arguments = []
            }
            return metadata
        }

        /// The line for a key the format requires, or an error when it is missing.
        private mutating func required(_ key: String) -> MetadataLine? {
            guard let line = fields[key] else {
                problems.append(.error(Strings.Problem.missing(key, prefix: prefix)))
                return nil
            }
            return line
        }

        private mutating func icon(_ key: String) -> String? {
            guard let line = fields[key] else { return nil }
            guard ScriptIcon.isValid(line.value) else {
                problems.append(.warning(Strings.Problem.icon(line.value), line: line.line))
                return nil
            }
            return line.value
        }

        private mutating func refreshTime(mode: ScriptMode) -> Duration? {
            guard let line = fields["refreshTime"] else {
                if mode == .inline { problems.append(.warning(Strings.Problem.inlineWithoutRefresh)) }
                return nil
            }
            guard mode == .inline else {
                problems.append(.warning(Strings.Problem.refreshOnlyInline, line: line.line))
                return nil
            }
            guard let duration = HeaderParser.duration(line.value) else {
                problems.append(.error(Strings.Problem.refreshTime(line.value), line: line.line))
                return nil
            }
            if duration < minimumRefresh {
                problems.append(.warning(Strings.Problem.refreshTooShort(line.value), line: line.line))
                return minimumRefresh
            }
            return duration
        }

        private mutating func filterAction(mode: ScriptMode) -> FilterAction {
            guard let line = fields["filterAction"] else { return .auto }
            guard mode == .list else {
                problems.append(.warning(Strings.Problem.filterActionOnlyList, line: line.line))
                return .auto
            }
            guard let action = FilterAction(rawValue: line.value) else {
                problems.append(.warning(Strings.Problem.filterAction(line.value), line: line.line))
                return .auto
            }
            return action
        }

        private mutating func arguments() -> [ScriptArgument] {
            var arguments: [ScriptArgument] = []
            for index in 1...3 {
                guard let line = fields["argument\(index)"] else { continue }
                guard arguments.count == index - 1 else {
                    problems.append(.error(Strings.Problem.argumentGap(index), line: line.line))
                    continue
                }
                var found: [ScriptProblem] = []
                let argument = ArgumentParser.parse(line.value, index: index, line: line.line, problems: &found)
                problems += found
                if let argument { arguments.append(argument) }
            }
            return arguments
        }
    }

    /// `10s`, `5m`, `12h` or `1d`: a whole number and one unit.
    static func duration(_ text: String) -> Duration? {
        guard let unit = text.last, text.count >= 2, text.count <= 8,
            text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }), let amount = Int(text.dropLast())
        else { return nil }
        let seconds: Int
        switch unit {
        case "s": seconds = amount
        case "m": seconds = amount * 60
        case "h": seconds = amount * 3600
        case "d": seconds = amount * 86_400
        default: return nil
        }
        return seconds > 0 ? .seconds(seconds) : nil
    }
}

/// Reads one `argumentN` value, a JSON object such as
/// `{ "type": "text", "placeholder": "name", "optional": true, "percentEncoded": true }`.
nonisolated enum ArgumentParser {
    static let knownFields: Set<String> = ["type", "placeholder", "optional", "percentEncoded", "data", "secure"]

    static func parse(_ json: String, index: Int, line: Int, problems: inout [ScriptProblem]) -> ScriptArgument? {
        guard let object = try? JSONValue.decode(Data(json.utf8), maximumDepth: 4).object else {
            problems.append(.error(Strings.Problem.argumentJSON(index), line: line))
            return nil
        }
        for field in object.keys.sorted() where !knownFields.contains(field) {
            problems.append(.warning(Strings.Problem.argumentUnknownField(index, field), line: line))
        }
        var isOptional = false
        var isPercentEncoded = false
        for (field, value) in [("optional", object["optional"]), ("percentEncoded", object["percentEncoded"])] {
            guard let value else { continue }
            guard let flag = value.bool else {
                problems.append(.warning(Strings.Problem.argumentField(index, field), line: line))
                continue
            }
            if field == "optional" { isOptional = flag } else { isPercentEncoded = flag }
        }
        guard let placeholder = object["placeholder"]?.string?.trimmed, !placeholder.isEmpty else {
            problems.append(.error(Strings.Problem.argumentPlaceholder(index), line: line))
            return nil
        }
        let kind: ScriptArgument.Kind
        let isSecure = object["secure"]?.bool == true
        if object["secure"] != nil {
            problems.append(.warning(Strings.Problem.argumentSecure(index), line: line))
        }
        switch object["type"] {
        case .none:
            if !isSecure { problems.append(.warning(Strings.Problem.argumentNoType(index), line: line)) }
            kind = isSecure ? .password : .text
        case .string("text"):
            kind = isSecure ? .password : .text
        case .string("password"):
            kind = .password
        case .string("dropdown"):
            guard let choices = choices(object["data"]) else {
                problems.append(.error(Strings.Problem.dropdownData(index), line: line))
                return nil
            }
            kind = .dropdown(choices)
        case .some(let other):
            problems.append(.error(Strings.Problem.argumentType(index, other.scalarText ?? "?"), line: line))
            return nil
        }
        if object["data"] != nil && object["type"] != .string("dropdown") {
            problems.append(.warning(Strings.Problem.dataIgnored(index), line: line))
        }
        return ScriptArgument(
            kind: kind, placeholder: placeholder, isOptional: isOptional, isPercentEncoded: isPercentEncoded)
    }

    /// The dropdown's choices, or nil unless every entry has a string title and value.
    private static func choices(_ value: JSONValue?) -> [ScriptArgument.Choice]? {
        guard let entries = value?.array, !entries.isEmpty else { return nil }
        var choices: [ScriptArgument.Choice] = []
        for entry in entries {
            guard let title = entry.object?["title"]?.string, let value = entry.object?["value"]?.string else {
                return nil
            }
            choices.append(ScriptArgument.Choice(title: title, value: value))
        }
        return choices
    }
}
