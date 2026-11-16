import Foundation
import Kit
import KitTesting
import Testing

/// The fakes behind the services added for features: change streams, keyword commands, usage
/// scores, app names, and HTTP streams a test can stop.
@Suite("Service fakes", .timeLimit(.minutes(1)))
struct ServiceFakeTests {
    @Test func permissionChangesReachListeners() async {
        let permissions = FakePermissions(defaultStatus: .notDetermined)
        var changes = permissions.changes(of: .inputMonitoring).makeAsyncIterator()
        permissions.set(.accessibility, to: .granted)
        permissions.set(.inputMonitoring, to: .granted)
        #expect(await changes.next() == .granted)
    }

    @Test func aTypedKeywordCanOpenACommand() async {
        let expansion = FakeTextExpansion()
        let form = ItemID.command(feature: "snippets", command: "fill")
        _ = await expansion.start(keywords: [";a", ";b"], options: ExpansionOptions()) { keyword in
            keyword == ";a" ? .runCommand(form, arguments: ["id": "1"]) : .ignore
        }
        #expect(await expansion.type(";a") == .runCommand(form, arguments: ["id": "1"]))
        #expect(await expansion.type(";b") == .ignore)
        #expect(await expansion.type(";c") == nil)
        #expect(expansion.commandRuns == [CommandRun(id: form, arguments: ["id": "1"])])
        #expect(expansion.inserted.isEmpty)
    }

    @Test func statusChangesWaitForTheirConsumer() async {
        let fakes = FakeServices()
        let seen = StatusLog()
        // Subscribe before starting the task, so nothing sent in between is lost.
        let statuses = fakes.textExpansion.statusChanges()
        let watcher = Task {
            for await status in statuses { await seen.add(status) }
        }
        fakes.textExpansion.simulateStatus(.blockedBySecureInput(owner: "Example"))
        await fakes.settle()
        #expect(await seen.statuses == [.blockedBySecureInput(owner: "Example")])
        watcher.cancel()
    }

    @Test func usageKeepsSnapshotsScoresAndForgets() {
        let clock = FakeClock()
        let usage = FakeUsage(clock: clock)
        let row = Row(id: ItemID("emoji", "a"), title: "A")
        usage.recordUse(of: row)
        clock.advance(by: .seconds(7 * 86_400))
        usage.recordUse(of: ItemID("emoji", "b"))
        usage.recordUse(of: Row(id: ItemID("emoji", "c"), title: "C", memory: .never))
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 2).map(\.id.key) == ["c", "b"])
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 5).map(\.snapshot) == [nil, nil, row])
        #expect(usage.frecency(namespace: "emoji")[row.id] == 0.5, "one use a week ago counts half")
        usage.forget(row.id)
        #expect(usage.useCount(of: row.id) == 0)
        usage.forgetAll(namespace: "emoji")
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 5).isEmpty)
    }

    @Test func theWorkspaceNamesInstalledApps() {
        let workspace = FakeWorkspace()
        workspace.installed = [AppInfo(bundleID: "com.example.editor", name: "Editor")]
        #expect(workspace.application(bundleID: "com.example.editor")?.name == "Editor")
        #expect(workspace.application(bundleID: "com.example.missing") == nil)
    }

    @Test func theWorkspaceCanRefuseToLaunchOneApp() async throws {
        let workspace = FakeWorkspace()
        workspace.refusesToLaunch = ["com.example.missing"]
        await #expect(throws: FakeWorkspaceError.refused) {
            try await workspace.launch(bundleID: "com.example.missing")
        }
        try await workspace.launch(bundleID: "com.example.present")
        #expect(workspace.launched == ["com.example.present"], "a refused launch is not recorded")
        workspace.refusesToLaunch = []
        try await workspace.launch(bundleID: "com.example.missing")
        #expect(workspace.launched == ["com.example.present", "com.example.missing"])
    }

    @Test func aStreamThatStaysOpenRecordsItsCancellation() async throws {
        let http = FakeHTTP()
        let url = try #require(URL(string: "https://ai.example.test/answer"))
        http.stub(url) { request in
            request.body == nil ? .chunks(["first"], keepsOpen: true) : .failure(URLError(.notConnectedToInternet))
        }
        let response = try await http.stream(HTTPRequest(url))
        let reader = Task {
            for try await _ in response.body {}
        }
        while http.requests.isEmpty { await Task.yield() }
        reader.cancel()
        _ = await reader.result
        #expect(http.cancelledRequests.map(\.url) == [url])
        await #expect(throws: URLError.self) { try await http.send(HTTPRequest(url, body: Data("x".utf8))) }
    }
}

/// Statuses a background loop saw, for a test to read.
private actor StatusLog {
    private(set) var statuses: [TextExpansionStatus] = []

    func add(_ status: TextExpansionStatus) {
        statuses.append(status)
    }
}
