import Foundation
import Kit
import KitTesting
import Testing

/// Scenario 7, script commands and script filters: commands found on disk and registered again when
/// the folder changes, an argument, the four output modes (silent with a HUD, compact toast, full
/// output streamed into a detail, inline subtitle), and a list driven by JSON from a subprocess with
/// rerun and per-row alternates while Command is held.
final class ScriptSketch: Feature {
    static let manifest = FeatureManifest(id: "scripts", name: "Script Commands", icon: .symbol("terminal"))

    nonisolated struct Script: Sendable {
        var url: URL
        var title: String
        var mode: String
        var argument: String?
    }

    let context: FeatureContext
    let folder: URL
    let changes = ChangeSignal()
    private(set) var scripts: [Script] = []
    private var watcher: Task<Void, Never>?

    convenience init(context: FeatureContext) {
        self.init(context: context, folder: URL(filePath: "/nonexistent"))
    }

    init(context: FeatureContext, folder: URL) {
        self.context = context
        self.folder = folder
    }

    func activate() async {
        await rescan()
        let changes = context.fileWatcher.watch([folder])
        watcher = Task { [weak self] in
            for await _ in changes { await self?.rescan() }
        }
    }

    func deactivate() async {
        watcher?.cancel()
    }

    private func rescan() async {
        scripts = await Self.scan(folder)
        changes.send()
    }

    /// Reads metadata lines such as `# @slick.title Hello` off the main thread.
    @concurrent nonisolated static func scan(_ folder: URL) async -> [Script] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var metadata: [String: String] = [:]
            for line in text.split(separator: "\n") where line.hasPrefix("# @slick.") {
                let parts = line.dropFirst("# @slick.".count).split(separator: " ", maxSplits: 1)
                if parts.count == 2 { metadata[String(parts[0])] = String(parts[1]) }
            }
            guard let title = metadata["title"], let mode = metadata["mode"] else { return nil }
            return Script(url: url, title: title, mode: mode, argument: metadata["argument1"])
        }
    }

    var declarationChanges: ChangeSignal? { changes }

    var commands: [Command] {
        scripts.map { script in
            let processes = context.processes
            let request = { (arguments: [String]) in ProcessRequest(executable: script.url, arguments: arguments) }
            let inline: LiveSubtitle? =
                script.mode == "inline"
                ? LiveSubtitle(every: .seconds(60)) {
                    (try? await processes.run(request([]))).map { LiveSubtitle.Value($0.output.lastLine) }
                } : nil
            return Command(
                id: "script." + script.url.lastPathComponent, title: script.title,
                arguments: script.argument.map { [CommandArgument("1", placeholder: $0, isOptional: true)] } ?? [],
                liveSubtitle: inline
            ) { context in
                let arguments = context.arguments["1"].map { [$0] } ?? []
                switch script.mode {
                case "fullOutput":
                    return .push(
                        .detail(
                            DetailPage(
                                title: script.title,
                                source: ScriptOutput(processes: processes, request: request(arguments)))))
                case "filter":
                    return .push(.list(ListPage(ScriptFilter(processes: processes, script: script.url))))
                default:
                    // A silent script closes the panel at once and reports when it finishes.
                    if script.mode == "silent" { context.dismiss() }
                    let result = try await processes.run(request(arguments))
                    let line = (result.exitCode == 0 ? result.output : result.errorOutput).lastLine
                    // Shown in the panel, or as a HUD when the panel is closed.
                    context.showToast(result.exitCode == 0 ? .success(line) : .failure(line))
                    return script.mode == "silent" ? .close() : .keepOpen
                }
            }
        }
    }
}

/// A script's full output, streamed as it arrives. `textStream` decodes off the main thread and
/// never splits a character.
final class ScriptOutput: DetailSource {
    private let processes: any ProcessService
    private let request: ProcessRequest

    init(processes: any ProcessService, request: ProcessRequest) {
        self.processes = processes
        self.request = request
    }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let events = processes.textStream(request)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DetailUpdate.self)
        let task = Task.detached {
            do {
                continuation.yield(.replace(Detail(.text("", monospaced: true))))
                for try await event in events {
                    switch event {
                    case .stdout(let text), .stderr(let text): continuation.yield(.append(text))
                    case .exit(let code): continuation.yield(.metadata([.label("Exit code", value: String(code))]))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The host passes what it shows, so the source keeps no copy of the output.
    func actions(for detail: Detail) -> [Action] {
        var actions: [Action] = []
        if case .text(let output, _) = detail.body { actions.append(.copy(output, title: "Copy Output")) }
        actions.append(
            Action("Run Again", shortcut: .refresh) { context in
                context.reload()
                return .keepOpen
            })
        return actions
    }
}

/// A list fed by a script's JSON for each query, in the Script Filter format.
final class ScriptFilter: ListSource {
    nonisolated struct Output: Decodable {
        var rerun: Double?
        var items: [Item]
    }

    nonisolated struct Item: Codable, Hashable, Sendable {
        nonisolated struct Modifier: Codable, Hashable, Sendable {
            var subtitle: String?
            var arg: String?
        }

        var uid: String?
        var title: String
        var subtitle: String?
        var arg: String?
        var mods: [String: Modifier]?
    }

    private let processes: any ProcessService
    private let script: URL

    init(processes: any ProcessService, script: URL) {
        self.processes = processes
        self.script = script
    }

    var filtering: ListFiltering { .custom(debounce: .milliseconds(100)) }

    func load(_ request: ListRequest) async throws -> ListResult {
        let result = try await processes.run(ProcessRequest(executable: script, arguments: [request.query]))
        return try await Self.parse(result.stdout)
    }

    /// Decodes the JSON and builds rows off the main thread. Each row carries its item in memory.
    @concurrent nonisolated static func parse(_ json: Data) async throws -> ListResult {
        let output = try JSONDecoder().decode(Output.self, from: json)
        let rows = output.items.map { item in
            Row(
                id: ItemID("script-filter", item.uid ?? item.title), title: item.title, subtitle: item.subtitle,
                payload: Payload(item),
                alternates: item.mods?["cmd"].map { [Row.Alternate(modifiers: .command, subtitle: $0.subtitle)] } ?? [])
        }
        return ListResult(rows: rows, refreshAfter: output.rerun.map { .milliseconds(Int($0 * 1000)) })
    }

    func actions(for row: Row) -> [Action] {
        guard let item = try? row.payload?.decode(Item.self) else { return [] }
        var actions = [Action.copy(item.arg ?? item.title, title: "Copy")]
        if let alternate = item.mods?["cmd"] {
            actions.append(
                .copy(alternate.arg ?? item.title, title: "Copy Alternate", shortcut: .secondaryAction).with(
                    id: "copy-alternate"))
        }
        return actions
    }
}

extension String {
    /// The last non-empty line, for HUDs and toasts.
    fileprivate var lastLine: String {
        split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

@Suite("Scenario: script commands")
struct ScriptSketchTests {
    private let fakes = FakeServices()

    private func folder() throws -> URL {
        let folder = fakes.storage.root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ name: String, title: String, mode: String, in folder: URL, argument: String? = nil) throws {
        let lines =
            ["#!/bin/sh", "# @slick.title \(title)", "# @slick.mode \(mode)"]
            + (argument.map { ["# @slick.argument1 \($0)"] } ?? [])
        try lines.joined(separator: "\n").write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }

    private func activated(_ folder: URL) async -> FeatureHarness<ScriptSketch> {
        let harness = FeatureHarness(fakes: fakes) { ScriptSketch(context: $0, folder: folder) }
        await harness.activate()
        return harness
    }

    @Test func registersScriptsAgainWhenTheFolderChanges() async throws {
        let folder = try folder()
        try write("a.sh", title: "Say Hello", mode: "silent", in: folder)
        let harness = await activated(folder)
        #expect(harness.feature.commands.map(\.title) == ["Say Hello"])
        try write("b.sh", title: "Disk Usage", mode: "compact", in: folder)
        fakes.fileWatcher.simulateChange([folder.appending(path: "b.sh")])
        try await harness.settle()
        #expect(harness.feature.commands.map(\.title) == ["Say Hello", "Disk Usage"])
        #expect(harness.issues.isEmpty)
    }

    @Test func silentAndCompactModesReportTheLastLine() async throws {
        let folder = try folder()
        try write("a.sh", title: "Greet", mode: "silent", in: folder, argument: "name")
        try write("b.sh", title: "Check", mode: "compact", in: folder)
        fakes.processes.stub("a.sh") { .stdout("working\nHello \($0.arguments.first ?? "world")\n") }
        fakes.processes.stub("b.sh", output: .stderr("disk full\n", exitCode: 1))
        let harness = await activated(folder)
        try await harness.run("script.a.sh", arguments: ["1": "Kit"])
        #expect(harness.huds == [.success("Hello Kit")], "the panel closed first, so the toast became a HUD")
        try await harness.run("script.b.sh")
        #expect(harness.toasts.map(\.title) == ["disk full"])
        #expect(harness.toasts.map(\.style) == [.failure])
    }

    @Test func fullOutputStreamsIntoADetailAndInlineRefreshesASubtitle() async throws {
        let folder = try folder()
        try write("a.sh", title: "Build", mode: "fullOutput", in: folder)
        try write("b.sh", title: "Uptime", mode: "inline", in: folder)
        fakes.processes.stub(
            "a.sh", output: FakeProcessOutput(events: [.stdout(Data("step 1\n".utf8)), .stdout(Data("step 2\n".utf8))]))
        fakes.processes.stub("b.sh", output: .stdout("up 3 days\n"))
        let harness = await activated(folder)
        try await harness.run("script.a.sh")
        #expect(
            harness.detail
                == Detail(.text("step 1\nstep 2\n", monospaced: true), metadata: [.label("Exit code", value: "0")]))
        try await harness.perform("Run Again")
        #expect(fakes.processes.runs.count == 2)
        let subtitle = try #require(try harness.command("script.b.sh").liveSubtitle)
        #expect(await subtitle.fetch() == "up 3 days")
    }

    @Test func scriptFilterRowsCarryAlternatesAndRerun() async throws {
        let folder = try folder()
        try write("a.sh", title: "Search Issues", mode: "filter", in: folder)
        fakes.processes.stub("a.sh") { request in
            .stdout(
                #"{"rerun": 0.5, "items": [{"uid": "1", "title": "Issue \#(request.arguments[0])", "arg": "url-1", "mods": {"cmd": {"subtitle": "Copy the ID", "arg": "1"}}}]}"#
            )
        }
        let harness = await activated(folder)
        try await harness.run("script.a.sh")
        try await harness.setQuery("crash")
        #expect(harness.rows.map(\.title) == ["Issue crash"])
        #expect(harness.page?.refreshAfter == .milliseconds(500))
        #expect(harness.selectedRow?.alternate(for: .command)?.subtitle == "Copy the ID")
        #expect(harness.actions().map(\.shortcut) == [nil, .secondaryAction])
        try await harness.perform("copy-alternate")
        #expect(fakes.pasteboard.copiedTexts == ["1"])
    }
}
