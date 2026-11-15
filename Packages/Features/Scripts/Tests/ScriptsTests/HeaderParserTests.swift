import Foundation
import Kit
import Testing

@testable import Scripts

/// Headers shaped like those in the public script command collections, and broken ones.
@Suite("Header parsing", .timeLimit(.minutes(1)))
struct HeaderParserTests {
    /// A header that parses, and what it must produce.
    struct Valid: CustomTestStringConvertible, Sendable {
        var name: String
        var header: String
        var check: @Sendable (ScriptMetadata, [ScriptProblem]) -> Void
        var testDescription: String { name }
    }

    nonisolated static let valid: [Valid] = [
        Valid(name: "the three required keys", header: Fixture.script()) { metadata, problems in
            #expect(metadata.title == "Say Hello")
            #expect(metadata.mode == .compact)
            #expect(metadata.schemaVersion == 1)
            #expect(problems.isEmpty)
        },
        Valid(name: "the feature's own prefix", header: Fixture.script("silent", prefix: Fixture.own)) {
            metadata, problems in
            #expect(metadata.mode == .silent)
            #expect(problems.isEmpty)
        },
        Valid(
            name: "every optional key",
            header: Fixture.script(
                "fullOutput",
                extra: [
                    "icon 🤖", "iconDark images/dark.png", "packageName Developer Utils", "currentDirectoryPath ~/work",
                    "needsConfirmation true", "description Shows a greeting.", "author Example Author",
                    "authorURL https://example.com", "platform macos",
                    #"argument1 { "type": "text", "placeholder": "from city", "percentEncoded": true }"#,
                    #"argument2 { "type": "text", "placeholder": "to city", "optional": true }"#,
                    #"argument3 { "type": "dropdown", "placeholder": "Size", "data": [{"title": "Small", "value": "s"}, {"title": "Large", "value": "l"}] }"#,
                ])
        ) { metadata, problems in
            #expect(problems.isEmpty)
            #expect(metadata.icon == "🤖")
            #expect(metadata.iconDark == "images/dark.png")
            #expect(metadata.packageName == "Developer Utils")
            #expect(metadata.currentDirectoryPath == "~/work")
            #expect(metadata.needsConfirmation)
            #expect(metadata.description == "Shows a greeting.")
            #expect(
                metadata.arguments == [
                    ScriptArgument(kind: .text, placeholder: "from city", isOptional: false, isPercentEncoded: true),
                    ScriptArgument(kind: .text, placeholder: "to city", isOptional: true, isPercentEncoded: false),
                    ScriptArgument(
                        kind: .dropdown([.init(title: "Small", value: "s"), .init(title: "Large", value: "l")]),
                        placeholder: "Size", isOptional: false, isPercentEncoded: false),
                ])
        },
        Valid(
            name: "JavaScript comments",
            header:
                "#!/usr/bin/env node\n// @raycast.schemaVersion 1\n// @raycast.title Node Script\n// @raycast.mode compact\n"
        ) { metadata, problems in
            #expect(metadata.title == "Node Script")
            #expect(problems.isEmpty)
        },
        Valid(
            name: "AppleScript comments and no space after the marker",
            header: "--@raycast.schemaVersion 1\n#@raycast.title Apple\n-- @raycast.mode silent\r\n"
        ) { metadata, problems in
            #expect(metadata.title == "Apple")
            #expect(metadata.mode == .silent)
            #expect(problems.isEmpty)
        },
        Valid(name: "inline with a refresh time", header: Fixture.script("inline", extra: ["refreshTime 1m"])) {
            metadata, problems in
            #expect(metadata.refreshTime == .seconds(60))
            #expect(metadata.effectiveMode == .inline)
            #expect(problems.isEmpty)
        },
        Valid(name: "inline without a refresh time runs as compact", header: Fixture.script("inline")) {
            metadata, problems in
            #expect(metadata.effectiveMode == .compact)
            #expect(problems.map(\.message) == [Strings.Problem.inlineWithoutRefresh])
        },
        Valid(name: "a refresh under ten seconds", header: Fixture.script("inline", extra: ["refreshTime 5s"])) {
            metadata, problems in
            #expect(metadata.refreshTime == .seconds(10))
            #expect(problems.map(\.severity) == [.warning])
        },
        Valid(name: "a refresh time on a compact script", header: Fixture.script(extra: ["refreshTime 1h"])) {
            metadata, problems in
            #expect(metadata.refreshTime == nil)
            #expect(problems.map(\.message) == [Strings.Problem.refreshOnlyInline])
        },
        Valid(
            name: "a list script with a filter action",
            header: Fixture.script("list", prefix: Fixture.own, extra: ["filterAction copy"])
        ) { metadata, problems in
            #expect(metadata.mode == .list)
            #expect(metadata.filterAction == .copy)
            #expect(problems.isEmpty)
        },
        Valid(
            name: "the filter action under the public prefix",
            header: Fixture.script("list", extra: ["filterAction paste"])
        ) { metadata, problems in
            #expect(metadata.filterAction == .auto)
            #expect(problems.count == 1)
            #expect(problems.first?.line == 5)
        },
        Valid(
            name: "unknown, duplicate and empty keys",
            header: Fixture.script(extra: ["colour red", "title Second Title", "packageName"])
        ) { metadata, problems in
            #expect(metadata.title == "Say Hello")
            #expect(metadata.packageName == nil)
            #expect(problems.map(\.severity) == [.warning, .warning, .warning])
            #expect(problems.map(\.line) == [5, 6, 7])
        },
        Valid(
            name: "both prefixes in one file",
            header: "# @raycast.schemaVersion 1\n# \(Fixture.own)title Mixed\n# @raycast.mode compact\n"
        ) { metadata, problems in
            #expect(metadata.title == "Mixed")
            #expect(problems.isEmpty)
        },
        Valid(
            name: "an argument without a type, and the old secure flag",
            header: Fixture.script(extra: [
                #"argument1 { "placeholder": "query" }"#,
                #"argument2 { "type": "text", "placeholder": "token", "secure": true }"#,
            ])
        ) { metadata, problems in
            #expect(metadata.arguments.map(\.kind) == [.text, .password])
            #expect(problems.map(\.severity) == [.warning, .warning])
        },
        Valid(
            name: "an icon that is not an emoji, a path or https",
            header: Fixture.script(extra: ["icon http://example.com/icon.png"])
        ) { metadata, problems in
            #expect(metadata.icon == nil)
            #expect(problems.map(\.severity) == [.warning])
        },
        Valid(
            name: "a list script ignores its arguments",
            header: Fixture.script(
                "list",
                extra: [
                    #"argument1 { "type": "text", "placeholder": "query" }"#
                ])
        ) { metadata, problems in
            #expect(metadata.arguments.isEmpty)
            #expect(problems.map(\.message) == [Strings.Problem.argumentsInList])
        },
    ]

    @Test(arguments: valid)
    func parses(_ testCase: Valid) throws {
        let parsed = HeaderParser.parse(testCase.header)
        #expect(parsed.isScript)
        let metadata = try #require(parsed.metadata, "\(parsed.problems)")
        testCase.check(metadata, parsed.problems)
    }

    /// A header that must not become a command, and the error it must report.
    struct Broken: CustomTestStringConvertible, Sendable {
        var name: String
        var header: String
        var error: String
        var line: Int?
        var testDescription: String { name }
    }

    nonisolated static let broken: [Broken] = [
        Broken(
            name: "no schema version", header: "# @raycast.title A\n# @raycast.mode compact\n",
            error: Strings.Problem.missing("schemaVersion", prefix: "@raycast.")),
        Broken(
            name: "schema version 2",
            header: Fixture.script().replacingOccurrences(of: "schemaVersion 1", with: "schemaVersion 2"),
            error: Strings.Problem.schemaVersion("2"), line: 2),
        Broken(
            name: "no title", header: "# \(Fixture.own)schemaVersion 1\n# \(Fixture.own)mode compact\n",
            error: Strings.Problem.missing("title", prefix: Fixture.own)),
        Broken(
            name: "an empty title", header: Fixture.script(title: ""),
            error: Strings.Problem.missing("title", prefix: "@raycast.")),
        Broken(
            name: "an unknown mode", header: Fixture.script("verbose"), error: Strings.Problem.mode("verbose"), line: 4),
        Broken(
            name: "a mode in the wrong case", header: Fixture.script("Compact"), error: Strings.Problem.mode("Compact"),
            line: 4),
        Broken(
            name: "an argument that is not JSON", header: Fixture.script(extra: ["argument1 type=text"]),
            error: Strings.Problem.argumentJSON(1), line: 5),
        Broken(
            name: "an argument that is a JSON list", header: Fixture.script(extra: [#"argument1 ["text"]"#]),
            error: Strings.Problem.argumentJSON(1), line: 5),
        Broken(
            name: "an argument without a placeholder",
            header: Fixture.script(extra: [#"argument1 { "type": "text" }"#]),
            error: Strings.Problem.argumentPlaceholder(1), line: 5),
        Broken(
            name: "a dropdown without data",
            header: Fixture.script(extra: [#"argument1 { "type": "dropdown", "placeholder": "Size" }"#]),
            error: Strings.Problem.dropdownData(1), line: 5),
        Broken(
            name: "a dropdown entry without a value",
            header: Fixture.script(extra: [
                #"argument1 { "type": "dropdown", "placeholder": "Size", "data": [{"title": "S"}] }"#
            ]),
            error: Strings.Problem.dropdownData(1), line: 5),
        Broken(
            name: "an unknown argument type",
            header: Fixture.script(extra: [#"argument1 { "type": "number", "placeholder": "n" }"#]),
            error: Strings.Problem.argumentType(1, "number"), line: 5),
        Broken(
            name: "a second argument without a first",
            header: Fixture.script(extra: [#"argument2 { "type": "text", "placeholder": "n" }"#]),
            error: Strings.Problem.argumentGap(2), line: 5),
        Broken(
            name: "an inline refresh time with no unit",
            header: Fixture.script("inline", extra: ["refreshTime 30"]),
            error: Strings.Problem.refreshTime("30"), line: 5),
        Broken(
            name: "an inline refresh time in words",
            header: Fixture.script("inline", extra: ["refreshTime soon"]),
            error: Strings.Problem.refreshTime("soon"), line: 5),
        Broken(
            name: "a script for Windows only", header: Fixture.script(extra: ["platform windows"]),
            error: Strings.Problem.platform("windows"), line: 5),
        Broken(
            name: "a title line with a colon",
            header: "# @raycast.schemaVersion 1\n# @raycast.title: Hello\n# @raycast.mode compact\n",
            error: Strings.Problem.missing("title", prefix: "@raycast.")),
    ]

    @Test(arguments: broken)
    func reportsErrors(_ testCase: Broken) {
        let parsed = HeaderParser.parse(testCase.header)
        #expect(parsed.isScript)
        #expect(parsed.metadata == nil)
        let error = parsed.problems.first { $0.severity == .error }
        #expect(error?.message == testCase.error)
        #expect(error?.line == testCase.line)
    }

    @Test func aFileWithoutMetadataIsNotAScript() {
        let parsed = HeaderParser.parse("#!/bin/bash\n# A helper the scripts source.\necho hello\n")
        #expect(!parsed.isScript)
        #expect(parsed.problems.isEmpty)
    }

    @Test func metadataOutsideCommentsIsIgnored() {
        let header = Fixture.script() + "\necho '@raycast.title Not This'\nTITLE=\"# @raycast.mode silent\"\n"
        let parsed = HeaderParser.parse(header)
        #expect(parsed.metadata?.title == "Say Hello")
        #expect(parsed.metadata?.mode == .compact)
    }

    @Test func refreshTimesUseOneUnit() {
        #expect(HeaderParser.duration("10s") == .seconds(10))
        #expect(HeaderParser.duration("5m") == .seconds(300))
        #expect(HeaderParser.duration("12h") == .seconds(43_200))
        #expect(HeaderParser.duration("1d") == .seconds(86_400))
        for bad in ["", "s", "1", "1w", "1.5m", "-1m", "0s", "1 m", "99999999s"] {
            #expect(HeaderParser.duration(bad) == nil, "\(bad)")
        }
    }
}

@Suite("Interpreters and requests", .timeLimit(.minutes(1)))
struct InterpreterTests {
    @Test(arguments: [
        ("#!/bin/bash\n", "sh", "/bin/bash", [String]()),
        ("#!/bin/bash -l\n", "sh", "/bin/bash", ["-l"]),
        ("#! /usr/bin/env python3\n", "py", "/usr/bin/env", ["python3"]),
        ("#!/usr/bin/osascript -l JavaScript\r\n", "js", "/usr/bin/osascript", ["-l", "JavaScript"]),
        ("# @raycast.title A\n", "applescript", "/usr/bin/osascript", []),
        ("# @raycast.title A\n", "ZSH", "/bin/zsh", []),
    ])
    func findsTheInterpreter(header: String, fileExtension: String, executable: String, arguments: [String]) throws {
        let interpreter = try Interpreter.resolve(header: header, fileExtension: fileExtension).get()
        #expect(interpreter.executable.path == executable)
        #expect(interpreter.arguments == arguments)
    }

    @Test(arguments: [("#!python3\n", "py"), ("#!\n", "sh"), ("# @raycast.title A\n", "py"), ("", "rb")])
    func refusesAScriptWithoutOne(header: String, fileExtension: String) {
        guard case .failure(let problem) = Interpreter.resolve(header: header, fileExtension: fileExtension) else {
            Issue.record("expected a problem")
            return
        }
        #expect(problem.severity == .error)
        #expect(problem.line == 1)
    }

    private func script(_ text: String, folder: URL = URL(filePath: "/scripts", directoryHint: .isDirectory)) throws
        -> Script
    {
        let url = folder.appending(path: "hello.sh")
        let catalog = ScriptCatalog.make(
            [FolderListing(folder: folder, exists: true, files: [ScriptFile(url: url, header: text)])],
            folders: [ScriptFolder(url: folder, isDefault: true, isEnabled: true)])
        return try #require(catalog.entries.first?.script)
    }

    private let settings = RunSettings(
        timeout: .seconds(30), timeoutName: "30 seconds", outputLimit: 1024, outputLimitName: "1 KB",
        searchPath: "/custom/bin:/usr/bin", home: URL(filePath: "/home/test", directoryHint: .isDirectory))

    @Test func runsThroughTheInterpreterInTheScriptFolder() throws {
        let script = try script(Fixture.script(shebang: "#!/usr/bin/env ruby -w"))
        let request = script.request(arguments: ["one"], variables: ["QUERY_STATE": "2"], settings: settings)
        #expect(request.executable.path == "/usr/bin/env")
        #expect(request.arguments == ["ruby", "-w", "/scripts/hello.sh", "one"])
        #expect(request.environment == ["PATH": "/custom/bin:/usr/bin", "QUERY_STATE": "2"])
        #expect(request.currentDirectory?.path == "/scripts")
        #expect(request.timeout == .seconds(30))
    }

    @Test(arguments: [("work", "/scripts/work"), ("~/projects", "/home/test/projects"), ("/tmp/x/../y", "/tmp/y")])
    func honorsTheCurrentDirectory(path: String, expected: String) throws {
        let script = try script(Fixture.script(extra: ["currentDirectoryPath \(path)"]))
        #expect(script.request(arguments: [], settings: settings).currentDirectory?.path == expected)
    }

    @Test func passesArgumentsInPlaceAndEncodesThoseThatAskForIt() throws {
        let script = try script(
            Fixture.script(extra: [
                #"argument1 { "type": "text", "placeholder": "a", "optional": true }"#,
                #"argument2 { "type": "text", "placeholder": "b", "optional": true, "percentEncoded": true }"#,
                #"argument3 { "type": "text", "placeholder": "c", "optional": true }"#,
            ]))
        #expect(
            script.processArguments(from: CommandArguments(["argument2": "a b&c=d/é"])) == [
                "", "a%20b%26c%3Dd%2F%C3%A9",
            ])
        #expect(script.processArguments(from: CommandArguments(["argument1": "x"])) == ["x"])
        #expect(script.processArguments(from: CommandArguments()) == [])
        #expect(script.commandArguments.map(\.name) == ["argument1", "argument2", "argument3"])
        #expect(script.acceptsTypedText)
    }

    @Test func resolvesIcons() {
        let folder = URL(filePath: "/scripts", directoryHint: .isDirectory)
        let home = URL(filePath: "/home/test", directoryHint: .isDirectory)
        func icon(_ value: String, remote: Bool = false) -> Icon? {
            ScriptIcon.icon(value, folder: folder, home: home, allowsRemote: remote)
        }
        #expect(icon("🤖") == .glyph("🤖"))
        #expect(icon("images/a.png") == .image(path: "/scripts/images/a.png"))
        #expect(icon("icon.png") == .image(path: "/scripts/icon.png"))
        #expect(icon("~/a.png") == .image(path: "/home/test/a.png"))
        #expect(icon("https://example.com/a.png") == nil, "nothing is downloaded unless the user allows it")
        #expect(icon("https://example.com/a.png", remote: true) == .remote(URL(string: "https://example.com/a.png")!))
        #expect(icon("terminal") == nil)
    }
}
