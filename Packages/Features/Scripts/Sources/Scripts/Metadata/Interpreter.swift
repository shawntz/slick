import Foundation
import Kit

/// The program that runs a script, from the script's first line.
///
/// The script runs as `<executable> <arguments> <script path> <$1> <$2> <$3>`, so a script needs no
/// executable bit. `#!/usr/bin/env python3` becomes `/usr/bin/env python3 script.py`, which finds
/// the interpreter on the PATH in settings. macOS splits a first line's words the same way.
nonisolated struct Interpreter: Hashable, Sendable, Codable {
    var executable: URL
    var arguments: [String]

    /// Interpreters for files with no first line naming one.
    static let byExtension: [String: String] = [
        "sh": "/bin/sh", "bash": "/bin/bash", "zsh": "/bin/zsh", "applescript": "/usr/bin/osascript",
    ]

    /// The interpreter a header's first line names, or the one for the file's extension.
    static func resolve(header: String, fileExtension: String) -> Result<Interpreter, ScriptProblem> {
        // An editor may start the file with a byte order mark, which hides the first line's `#!`.
        let text = header.hasPrefix("\u{FEFF}") ? header.dropFirst() : Substring(header)
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }.trimmed
        if firstLine.hasPrefix("#!") {
            let words = firstLine.dropFirst(2).split { $0 == " " || $0 == "\t" }.map(String.init)
            guard let program = words.first, program.hasPrefix("/"), !program.contains("\0") else {
                return .failure(.error(Strings.Problem.interpreter(firstLine), line: 1))
            }
            return .success(Interpreter(executable: URL(filePath: program), arguments: Array(words.dropFirst())))
        }
        guard let program = byExtension[fileExtension.lowercased()] else {
            return .failure(.error(Strings.Problem.noInterpreter, line: 1))
        }
        return .success(Interpreter(executable: URL(filePath: program), arguments: []))
    }

    /// How the interpreter reads in Manage Script Commands, such as `/usr/bin/env python3`.
    var displayName: String {
        ([executable.path] + arguments).joined(separator: " ")
    }
}

/// A script's icon as its header writes it: an emoji, an image path or an `https` URL.
nonisolated enum ScriptIcon {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "icns", "heic", "pdf"]

    /// True for a value ``icon(_:folder:home:)`` can draw.
    static func isValid(_ value: String) -> Bool {
        if value.hasPrefix("https://") { return URL(string: value)?.host() != nil }
        if value.hasPrefix("http://") { return false }
        if isPath(value) { return true }
        return value.count <= 2 && value.unicodeScalars.contains { !$0.isASCII || $0.properties.isEmoji }
    }

    /// The icon for a header value. Paths are relative to the script's folder, or start with `/` or
    /// `~/`.
    static func icon(_ value: String?, folder: URL, home: URL) -> Icon? {
        guard let value, isValid(value) else { return nil }
        if value.hasPrefix("https://") { return URL(string: value).map(Icon.remote) }
        guard isPath(value) else { return .glyph(value) }
        return .image(path: ScriptPath.resolve(value, folder: folder, home: home).path)
    }

    private static func isPath(_ value: String) -> Bool {
        value.contains("/") || imageExtensions.contains((value as NSString).pathExtension.lowercased())
    }
}

/// Paths written in a header.
nonisolated enum ScriptPath {
    /// A path relative to the script's folder, absolute, or starting with `~/` for the home folder.
    static func resolve(_ path: String, folder: URL, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(filePath: path).standardizedFileURL }
        return folder.appending(path: path).standardizedFileURL
    }

    /// A folder's path as settings and comparisons use it: standardized, with no trailing slash.
    static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
