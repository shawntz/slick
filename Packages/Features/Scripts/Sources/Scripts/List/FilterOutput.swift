import Foundation
import Kit

/// One row a list script printed, as its actions need it. Rows carry it as their payload.
nonisolated struct FilterItem: Codable, Hashable, Sendable {
    var title: String
    /// The `arg` values: one string, or several from an array. Empty when the item has none.
    var arguments: [String]
    /// False makes Return complete ``autocomplete`` instead of acting.
    var isValid: Bool
    var autocomplete: String?
    /// True for `type` `file` or `file:skipcheck`: the argument is a path.
    var isFile: Bool
    /// The text Copy copies, from `text.copy`.
    var copyText: String?
    var variables: [String: String]
    var modifiers: [FilterModifier]
}

/// What a row does while modifier keys are held, from `mods`.
nonisolated struct FilterModifier: Codable, Hashable, Sendable {
    var modifiers: KeyModifiers
    /// Nil uses the item's arguments.
    var arguments: [String]?
    var subtitle: String?
    var isValid: Bool
    /// Replaces the item's variables when set, as the format says.
    var variables: [String: String]?
}

/// A parsed run of a list script.
nonisolated struct FilterPage: Sendable {
    var rows: [Row]
    /// When to run again with the same query, from `rerun`.
    var rerun: Duration?
    /// The session variables the script returned, passed back on its next runs.
    var variables: [String: String]
    /// What the user should know about rows left out.
    var notices: [String]
}

/// Reads the JSON a list script prints, in the Script Filter format documented at
/// https://www.alfredapp.com/help/workflows/inputs/script-filter/json/.
///
/// Read: `items` with `uid`, `title`, `subtitle`, `arg`, `icon`, `valid`, `autocomplete`, `type`,
/// `mods`, `text.copy`, `quicklookurl` and `variables`, and top-level `rerun` and `variables`. An
/// `arg` is one string or a list of them. An `icon` has a `path` and may have the `type` `fileicon`
/// or `filetype`. Ignored: `match`, `action`, `text.largetype`, `skipknowledge`, `cache` and the
/// legacy XML format.
///
/// The output is not trusted. Empty output, invalid JSON, nesting deeper than
/// ``maximumDepth`` and a missing `items` list are errors the page shows. An item without a title
/// is left out. Values of the wrong type are ignored. Text is cut to fixed lengths, at most
/// ``maximumItems`` rows are shown, and variables that could change how programs load or find
/// commands are dropped.
nonisolated enum FilterOutput {
    static let maximumDepth = 16
    static let maximumItems = 1000
    static let maximumTitleLength = 1000
    static let maximumArgumentLength = 64 * 1024
    static let maximumVariables = 64
    static let rerunRange = 0.1...5.0
    /// Variables a script may not set for its next run: the clean environment's own, and those that
    /// make a shell or an interpreter read or run other code when it starts. Output can carry text
    /// from anywhere, so it must not be able to choose the code that runs next.
    static let reservedVariables: Set<String> = [
        "PATH", "HOME", "LANG", "TMPDIR", "SHELL", "IFS", "ENV", "ZDOTDIR", "CDPATH", "PS4", "PROMPT_COMMAND",
        "SHELLOPTS", "BASHOPTS", "GLOBIGNORE", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME",
        "PYTHONSTARTUP", "PYTHONINSPECT", "PERL5LIB", "PERL5OPT", "PERLLIB", "RUBYOPT", "RUBYLIB", "GEM_HOME",
        "GEM_PATH", "JAVA_TOOL_OPTIONS", "OSA_LIBRARY_PATH",
    ]
    /// Prefixes of reserved names: the loader's, and the shell's own such as `BASH_ENV`.
    static let reservedPrefixes = ["DYLD_", "LD_", "BASH_", "LC_"]

    /// Why the output could not be read.
    nonisolated enum Failure: Error, Hashable, Sendable {
        case empty
        case invalid
        case tooDeep
        case noItems

        var message: String {
            switch self {
            case .empty: Strings.emptyOutput
            case .invalid: Strings.notJSON
            case .tooDeep: Strings.tooDeep
            case .noItems: Strings.noItems
            }
        }
    }

    /// What rows need to know about the script that printed them.
    nonisolated struct Source: Sendable {
        var namespace: String
        var commandID: String
        var folder: URL
        var home: URL
        var query: String
    }

    /// Parses off the main thread.
    @concurrent static func parse(_ data: Data, source: Source) async throws(Failure) -> FilterPage {
        try page(from: data, source: source)
    }

    static func page(from data: Data, source: Source) throws(Failure) -> FilterPage {
        let root: JSONValue
        do {
            root = try JSONValue.decode(data, maximumDepth: maximumDepth)
        } catch .empty {
            throw .empty
        } catch .tooDeep {
            throw .tooDeep
        } catch {
            throw .invalid
        }
        guard let object = root.object, let items = object["items"]?.array else { throw .noItems }
        var rows: [Row] = []
        var seen = Set<String>()
        var skipped = 0
        for (index, value) in items.prefix(maximumItems).enumerated() {
            guard let item = value.object, let row = row(item, index: index, source: source, seen: &seen) else {
                skipped += 1
                continue
            }
            rows.append(row)
        }
        var notices: [String] = []
        if skipped > 0 { notices.append(Strings.skippedItems(skipped)) }
        if items.count > maximumItems {
            notices.append(Strings.truncatedItems(shown: maximumItems, total: items.count))
        }
        let rerun = object["rerun"]?.number.flatMap { seconds -> Duration? in
            guard seconds.isFinite else { return nil }
            let clamped = min(max(seconds, rerunRange.lowerBound), rerunRange.upperBound)
            return .milliseconds(Int((clamped * 1000).rounded()))
        }
        return FilterPage(rows: rows, rerun: rerun, variables: variables(object["variables"]) ?? [:], notices: notices)
    }

    private static func row(_ item: [String: JSONValue], index: Int, source: Source, seen: inout Set<String>) -> Row? {
        guard let rawTitle = item["title"]?.string?.trimmed, !rawTitle.isEmpty else { return nil }
        let title = clip(rawTitle, maximumTitleLength)
        let subtitle = item["subtitle"]?.string.map { clip($0, maximumTitleLength) }
        let arguments = Self.arguments(item["arg"]) ?? []
        let isFile = item["type"]?.string.map { $0 == "file" || $0 == "file:skipcheck" } ?? false
        let modifiers = Self.modifiers(item["mods"], source: source)
        let filterItem = FilterItem(
            title: title, arguments: arguments, isValid: item["valid"]?.bool ?? true,
            autocomplete: item["autocomplete"]?.string.map { clip($0, maximumTitleLength) }, isFile: isFile,
            copyText: item["text"]?.object?["copy"]?.string.map { clip($0, maximumArgumentLength) },
            variables: variables(item["variables"]) ?? [:], modifiers: modifiers.map(\.modifier))

        var key = item["uid"]?.string.map { clip($0, 200) } ?? "#\(index)"
        if !seen.insert(key).inserted {
            key += "#\(index)"
            seen.insert(key)
        }
        let quickLook = item["quicklookurl"]?.string.flatMap { fileURL($0, home: source.home) }
        let firstPath = isFile ? arguments.first.flatMap { fileURL($0, home: source.home) } : nil
        return Row(
            id: ItemID(source.namespace, source.commandID + "/" + key), title: title, subtitle: subtitle,
            icon: icon(item["icon"], source: source), payload: Payload(filterItem), completion: filterItem.autocomplete,
            quickLookURL: quickLook ?? firstPath,
            alternates: modifiers.map(\.alternate), titleHighlights: highlights(of: source.query, in: title),
            memory: .never, represents: firstPath.map { .files([$0]) })
    }

    /// `arg` as a list of strings: one string, or an array whose strings are kept.
    private static func arguments(_ value: JSONValue?) -> [String]? {
        switch value {
        case .string(let text): [clip(text, maximumArgumentLength)]
        case .array(let values): values.compactMap(\.string).prefix(64).map { clip($0, maximumArgumentLength) }
        case .number, .bool: value?.scalarText.map { [$0] }
        default: nil
        }
    }

    private static func modifiers(_ value: JSONValue?, source: Source) -> [(
        modifier: FilterModifier, alternate: Row.Alternate
    )] {
        guard let mods = value?.object else { return [] }
        var result: [(modifier: FilterModifier, alternate: Row.Alternate)] = []
        for (name, value) in mods.sorted(by: { $0.key < $1.key }) {
            guard let mod = value.object, let keys = keyModifiers(name),
                !result.contains(where: { $0.modifier.modifiers == keys })
            else { continue }
            let subtitle = mod["subtitle"]?.string.map { clip($0, maximumTitleLength) }
            let modifier = FilterModifier(
                modifiers: keys, arguments: arguments(mod["arg"]), subtitle: subtitle,
                isValid: mod["valid"]?.bool ?? true, variables: variables(mod["variables"]))
            let alternate = Row.Alternate(modifiers: keys, subtitle: subtitle, icon: icon(mod["icon"], source: source))
            result.append((modifier, alternate))
        }
        return result
    }

    /// `cmd`, `alt`, `ctrl`, `shift`, `fn` and combinations such as `cmd+alt`. Nil for anything
    /// else, so a typo drops one modifier instead of the row.
    static func keyModifiers(_ name: String) -> KeyModifiers? {
        var result: KeyModifiers = []
        for part in name.split(separator: "+") {
            guard let modifier = KeyModifiers(name: part) else { return nil }
            result.insert(modifier)
        }
        return result.isEmpty ? nil : result
    }

    /// String variables with safe names. Numbers and booleans become text; other values are
    /// dropped.
    static func variables(_ value: JSONValue?) -> [String: String]? {
        guard let object = value?.object else { return nil }
        var result: [String: String] = [:]
        for (name, value) in object.sorted(by: { $0.key < $1.key }) where result.count < maximumVariables {
            guard isAllowedVariable(name), let text = value.scalarText else { continue }
            result[name] = clip(text, maximumArgumentLength)
        }
        return result
    }

    /// A name a shell can read, `[A-Za-z_][A-Za-z0-9_]*`, that is not reserved and does not start
    /// with a reserved prefix. Case is ignored, so `bash_env` is refused too.
    static func isAllowedVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 128,
            first == "_" || (first.isASCII && first.properties.isAlphabetic),
            name.unicodeScalars.allSatisfy({
                $0 == "_" || ($0.isASCII && $0.properties.isAlphabetic) || ("0"..."9").contains($0)
            })
        else { return false }
        let upper = name.uppercased()
        return !reservedVariables.contains(upper) && !reservedPrefixes.contains { upper.hasPrefix($0) }
    }

    private static func icon(_ value: JSONValue?, source: Source) -> Icon? {
        guard let object = value?.object, let path = object["path"]?.string, !path.isEmpty else { return nil }
        switch object["type"]?.string {
        case "fileicon": return .file(path: ScriptPath.resolve(path, folder: source.folder, home: source.home).path)
        case "filetype": return .fileType(path)
        default: return .image(path: ScriptPath.resolve(path, folder: source.folder, home: source.home).path)
        }
    }

    /// A local file for an absolute path or one under `~/`. Other text, URLs included, is not one.
    static func fileURL(_ text: String, home: URL) -> URL? {
        guard text.hasPrefix("/") || text.hasPrefix("~/") else { return nil }
        return ScriptPath.resolve(text, folder: home, home: home)
    }

    /// Where the query appears in the title, ignoring case and accents, in UTF-16 offsets.
    static func highlights(of query: String, in title: String) -> [Range<Int>] {
        let query = query.trimmed
        guard !query.isEmpty,
            let range = title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return [] }
        let start = title.utf16.distance(from: title.startIndex, to: range.lowerBound)
        return [start..<(start + title[range].utf16.count)]
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) : text
    }
}
