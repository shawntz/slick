import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Paths that could run a script without the user asking for it, or run other code than the user
/// meant. Every process is a fake.
@Suite("Safety", .timeLimit(.minutes(1)))
@MainActor
struct SafetyTests {
    // MARK: - Confirmation

    @Test(arguments: ["yes", "1", "on", "ask"])
    func aConfirmationValueThatIsNotTrueOrFalseStillAsks(value: String) throws {
        let parsed = HeaderParser.parse(Fixture.script(extra: ["needsConfirmation \(value)"]))
        let metadata = try #require(parsed.metadata)
        #expect(metadata.needsConfirmation)
        #expect(parsed.problems == [.warning(Strings.Problem.confirmation(value), line: 5)])
    }

    @Test func trueAndFalseAreReadInAnyCase() throws {
        let yes = HeaderParser.parse(Fixture.script(extra: ["needsConfirmation TRUE"]))
        #expect(try #require(yes.metadata).needsConfirmation)
        #expect(yes.problems.isEmpty)
        let no = HeaderParser.parse(Fixture.script(extra: ["needsConfirmation False"]))
        #expect(try #require(no.metadata).needsConfirmation == false)
        #expect(no.problems.isEmpty)
    }

    @Test func aMistypedConfirmationRunsNothingUntilTheUserAgrees() async throws {
        let bench = ScriptsBench(files: [
            "wipe.sh": Fixture.script(title: "Wipe Cache", extra: ["needsConfirmation yes"])
        ])
        bench.fakes.processes.stubScripts(["wipe.sh": .stdout("done\n")])
        await bench.start()
        bench.harness.confirmationAnswer = false
        try await bench.harness.run(bench.id("wipe.sh"))
        #expect(bench.harness.confirmations.map(\.title) == [Strings.confirmRun("Wipe Cache")])
        #expect(bench.fakes.processes.runs.isEmpty)
    }

    @Test func aScriptThatAsksFirstNeverRefreshesByItself() async throws {
        let bench = ScriptsBench(files: [
            "deploy.sh": Fixture.script(
                "inline", title: "Deploy Status", extra: ["refreshTime 10s", "needsConfirmation true"])
        ])
        bench.fakes.processes.stubScripts(["deploy.sh": .stdout("deployed\n")])
        await bench.start()
        let id = bench.id("deploy.sh")
        // Even a setting written by hand or by an older version cannot turn it on.
        bench.harness.context.settings[ScriptsSettings.refreshingInline] = [id]
        try await bench.harness.settle()
        let subtitle = try #require(try bench.harness.command(id).liveSubtitle)
        #expect(await subtitle.value() == nil)
        #expect(bench.fakes.processes.runs.isEmpty)
        #expect(try bench.harness.rowActions(ofCommand: id).map(\.id) == ["edit-with", "reveal", "copy-path"])

        var inlineChoices: [SettingsChoice] = []
        for item in try #require(bench.feature.settingsPane).sections.flatMap(\.items) {
            if case .multiSelect(let key, let options) = item.control, key.name == "refreshingInline" {
                inlineChoices = await options()
            }
        }
        #expect(inlineChoices.isEmpty)
    }

    // MARK: - Session variables

    @Test(arguments: [
        "BASH_ENV", "bash_env", "BASH_FUNC_ls", "ENV", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "PYTHONSTARTUP",
        "PERL5OPT", "RUBYOPT", "SHELLOPTS", "PROMPT_COMMAND", "LC_ALL", "DYLD_LIBRARY_PATH",
    ])
    func variablesThatMakeAnInterpreterRunOtherCodeAreRefused(name: String) {
        #expect(!FilterOutput.isAllowedVariable(name))
    }

    @Test func aListScriptCannotHandItsNextRunAStartupFile() async throws {
        let bench = ScriptsBench(files: ["find.sh": Fixture.script("list", title: "Find", prefix: Fixture.own)])
        bench.fakes.processes.stubScripts { _ in
            .stdout(
                #"""
                {"variables": {"BASH_ENV": "/tmp/x.sh", "ENV": "/tmp/x.sh", "NODE_OPTIONS": "--require /tmp/x.js",
                 "cursor": "2"}, "items": [{"title": "One"}]}
                """#)
        }
        await bench.start()
        try await bench.harness.run(bench.id("find.sh"))
        try await bench.harness.setQuery("o")
        let environment = try #require(bench.fakes.processes.runs.last?.environment)
        #expect(environment == ["PATH": ScriptsSettings.defaultSearchPath, "cursor": "2"])
    }

    /// Found in review: names that make git, Lua, Python, Java, Node or an HTTP client run code or
    /// connect elsewhere, in either case, and upper case names no list knows.
    @Test(arguments: [
        "GIT_SSH_COMMAND", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "git_config_count",
        "LUA_INIT", "Lua_Init", "BROWSER", "browser", "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
        "ALL_PROXY", "all_proxy", "no_proxy", "ftp_proxy", "SSL_CERT_FILE", "ssl_cert_file", "REQUESTS_CA_BUNDLE",
        "requests_ca_bundle", "NODE_EXTRA_CA_CERTS", "node_options", "_JAVA_OPTIONS", "_java_options",
        "JDK_JAVA_OPTIONS", "java_tool_options", "OPENSSL_CONF", "openssl_conf", "R_PROFILE_USER", "PHPRC", "phprc",
        "npm_config_script_shell", "pythonpath", "ssh_askpass", "curl_home", "fpath", "GOFLAGS", "RUSTC_WRAPPER",
        "DOCKER_HOST", "PAGE", "_2",
    ])
    func variablesThatMakeAToolRunCodeOrConnectElsewhereAreRefused(name: String) {
        #expect(!FilterOutput.isAllowedVariable(name))
    }

    @Test(arguments: ["page", "nextCursor", "query_2", "alfred_workflow_cache", "_cursor", "Token"])
    func aScriptsOwnVariablesAreKept(name: String) {
        #expect(FilterOutput.isAllowedVariable(name))
    }

    @Test func aListScriptCannotPointGitOrAProxyAtAnotherServer() async throws {
        let bench = ScriptsBench(files: ["find.sh": Fixture.script("list", title: "Find", prefix: Fixture.own)])
        bench.fakes.processes.stubScripts { _ in
            .stdout(
                #"""
                {"variables": {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor",
                 "GIT_CONFIG_VALUE_0": "/tmp/x.sh", "https_proxy": "http://203.0.113.9", "LUA_INIT": "@/tmp/x.lua",
                 "nextCursor": "2"}, "items": [{"title": "One"}]}
                """#)
        }
        await bench.start()
        try await bench.harness.run(bench.id("find.sh"))
        try await bench.harness.setQuery("o")
        let environment = try #require(bench.fakes.processes.runs.last?.environment)
        #expect(environment == ["PATH": ScriptsSettings.defaultSearchPath, "nextCursor": "2"])
    }

    @Test func zeroCharactersNeverReachAProcess() async throws {
        let bench = ScriptsBench(files: [
            "echo.sh": Fixture.script(
                title: "Echo", extra: [#"argument1 { "type": "text", "placeholder": "text" }"#]),
            "find.sh": Fixture.script("list", title: "Find", prefix: Fixture.own),
        ])
        bench.fakes.processes.stubScripts { request in
            Fixture.scriptName(request) == "find.sh"
                ? .stdout(#"{"variables": {"bad": "a\u0000b", "good": "c"}, "items": [{"title": "One"}]}"#)
                : .stdout("ok\n")
        }
        await bench.start()
        try await bench.harness.run(bench.id("echo.sh"), arguments: ["argument1": "a\0b"])
        try await bench.harness.run(bench.id("find.sh"))
        try await bench.harness.setQuery("x\0y")
        let runs = bench.fakes.processes.runs
        #expect(runs.map(Fixture.scriptArguments) == [["ab"], [""], ["xy"]])
        #expect(runs.last?.environment == ["PATH": ScriptsSettings.defaultSearchPath, "good": "c"])
        #expect(runs.allSatisfy { !$0.arguments.contains { $0.contains("\0") } })
    }

    // MARK: - The interpreter

    @Test func aByteOrderMarkDoesNotHideTheFirstLine() throws {
        let header =
            "\u{FEFF}#!/bin/zsh\n# @raycast.schemaVersion 1\n# @raycast.title Zsh Script\n# @raycast.mode compact\n"
        let interpreter = try Interpreter.resolve(header: header, fileExtension: "sh").get()
        #expect(interpreter.executable.path == "/bin/zsh")
        let markedFirst = "\u{FEFF}# @raycast.schemaVersion 1\n# @raycast.title Marked\n# @raycast.mode silent\n"
        let parsed = HeaderParser.parse(markedFirst)
        #expect(parsed.metadata?.title == "Marked")
        #expect(parsed.problems.isEmpty)
    }

    // MARK: - Turning the feature off and on

    @Test func turningTheFeatureOffAndOnKeepsWatchingOnce() async throws {
        let library = MemoryScriptLibrary()
        let bench = ScriptsBench(library: library)
        await bench.start()
        await bench.harness.deactivate()
        await bench.harness.activate()
        await bench.harness.activate()
        await bench.feature.scanned()

        library.write(Fixture.script(title: "Later"), at: bench.folder.appending(path: "later.sh"))
        let signal = try #require(bench.feature.declarationChanges)
        let before = signal.generation
        bench.fakes.fileWatcher.simulateChange([bench.folder.appending(path: "later.sh")])
        try await bench.harness.settle()
        await bench.feature.scanned()
        #expect(bench.scriptCommands.map(\.title) == ["Later"])
        #expect(signal.generation == before + 1, "one change, one signal")
    }
}
