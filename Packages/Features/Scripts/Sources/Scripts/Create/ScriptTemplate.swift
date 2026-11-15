import Foundation

/// A language Create Script Command can start a script in.
nonisolated enum ScriptLanguage: String, CaseIterable, Hashable, Sendable {
    case bash
    case zsh
    case python
    case ruby
    case node
    case swift
    case appleScript

    var name: String {
        switch self {
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .python: "Python"
        case .ruby: "Ruby"
        case .node: "Node.js"
        case .swift: "Swift"
        case .appleScript: "AppleScript"
        }
    }

    var fileExtension: String {
        switch self {
        case .bash: "sh"
        case .zsh: "zsh"
        case .python: "py"
        case .ruby: "rb"
        case .node: "js"
        case .swift: "swift"
        case .appleScript: "applescript"
        }
    }

    var shebang: String {
        switch self {
        case .bash: "#!/bin/bash"
        case .zsh: "#!/bin/zsh"
        case .python: "#!/usr/bin/env python3"
        case .ruby: "#!/usr/bin/env ruby"
        case .node: "#!/usr/bin/env node"
        case .swift: "#!/usr/bin/swift"
        case .appleScript: "#!/usr/bin/osascript"
        }
    }

    /// The comment marker for metadata lines.
    var comment: String {
        switch self {
        case .node, .swift: "//"
        case .bash, .zsh, .python, .ruby, .appleScript: "#"
        }
    }
}

/// The text of a new script: a first line naming the interpreter, a header in this feature's own
/// prefix, and a body that prints something in the chosen mode.
nonisolated enum ScriptTemplate {
    static func render(title: String, language: ScriptLanguage, mode: ScriptMode, packageName: String?) -> String {
        let marker = language.comment + " " + HeaderParser.ownPrefix
        var lines = [
            language.shebang, "",
            marker + "schemaVersion 1",
            marker + "title " + title,
            marker + "mode " + mode.rawValue,
        ]
        if mode == .inline { lines.append(marker + "refreshTime 5m") }
        lines += ["", language.comment + " " + Strings.templateOptionalHeading]
        lines.append(marker + "icon 🤖")
        if let packageName, !packageName.isEmpty { lines.append(marker + "packageName " + packageName) }
        if mode != .list {
            lines.append(marker + #"argument1 { "type": "text", "placeholder": "Name", "optional": true }"#)
        }
        lines += ["", language.comment + " " + Strings.templateDocumentation, ""]
        lines += mode == .list ? listBody(language) : body(language)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prints a greeting, with the first argument when one was given.
    private static func body(_ language: ScriptLanguage) -> [String] {
        let greeting = Strings.templateGreeting
        switch language {
        case .bash, .zsh:
            return [#"echo "\#(greeting) ${1}""#]
        case .python:
            return ["import sys", "", #"print("\#(greeting)", " ".join(sys.argv[1:]))"#]
        case .ruby:
            return [#"puts "\#(greeting) #{ARGV.join(" ")}""#]
        case .node:
            return [#"console.log("\#(greeting)", process.argv.slice(2).join(" "))"#]
        case .swift:
            return [#"print("\#(greeting)", CommandLine.arguments.dropFirst().joined(separator: " "))"#]
        case .appleScript:
            return ["on run argv", #"  return "\#(greeting) " & (item 1 of (argv & {""}))"#, "end run"]
        }
    }

    /// Prints Script Filter JSON with one row for the query.
    private static func listBody(_ language: ScriptLanguage) -> [String] {
        let typed = Strings.templateYouTyped
        switch language {
        case .bash, .zsh:
            return [
                #"query="${1//\\/\\\\}""#,
                #"query="${query//\"/\\\"}""#,
                #"cat <<EOF"#,
                #"{"items": [{"uid": "query", "title": "\#(typed) ${query}", "arg": "${query}"}]}"#,
                "EOF",
            ]
        case .python:
            return [
                "import json", "import sys", "",
                #"query = sys.argv[1] if len(sys.argv) > 1 else """#,
                #"print(json.dumps({"items": [{"uid": "query", "title": f"\#(typed) {query}", "arg": query}]}))"#,
            ]
        case .ruby:
            return [
                "require \"json\"", "",
                #"query = ARGV[0] || """#,
                #"puts({ items: [{ uid: "query", title: "\#(typed) #{query}", arg: query }] }.to_json)"#,
            ]
        case .node:
            return [
                #"const query = process.argv[2] || """#,
                #"console.log(JSON.stringify({ items: [{ uid: "query", title: `\#(typed) ${query}`, arg: query }] }))"#,
            ]
        case .swift:
            return [
                "import Foundation", "",
                #"let query = CommandLine.arguments.dropFirst().first ?? """#,
                #"let items: [[String: String]] = [["uid": "query", "title": "\#(typed) \(query)", "arg": query]]"#,
                #"let data = try JSONSerialization.data(withJSONObject: ["items": items])"#,
                "print(String(decoding: data, as: UTF8.self))",
            ]
        case .appleScript:
            return [
                "on run argv",
                #"  set query to item 1 of (argv & {""})"#,
                #"  return "{\"items\": [{\"uid\": \"query\", \"title\": \"\#(typed) " & query & "\", \"arg\": \"" & query & "\"}]}""#,
                "end run",
            ]
        }
    }

    /// A file name for a title: lowercase ASCII letters and digits joined by hyphens.
    static func fileName(for title: String, language: ScriptLanguage) -> String? {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII && (("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        let trimmed = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
        return trimmed.isEmpty ? nil : trimmed + "." + language.fileExtension
    }
}
