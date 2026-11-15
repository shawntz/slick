import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

/// Made-up processes. PID 99 is this app.
private nonisolated let editor = SimulatedProcessTable.sample(
    201, "Example Editor", app: "com.example.editor", memory: 400 << 20)
private nonisolated let browser = SimulatedProcessTable.sample(
    202, "Example Browser", app: "com.example.browser", memory: 1_500 << 20)
private nonisolated let indexer = SimulatedProcessTable.sample(203, "example-indexer", memory: 90 << 20)
private nonisolated let helper = SimulatedProcessTable.sample(204, "example-helper", memory: 20 << 20)
private nonisolated let everyone = [editor, browser, indexer, helper]
/// CPU use per process: the indexer is busiest.
private nonisolated let rates: [Int32: Double] = [201: 0.05, 202: 0.25, 203: 0.8, 204: 0]

@Suite("Kill Process", .timeLimit(.minutes(1)))
@MainActor
struct ProcessListTests {
    private func opened(
        _ processes: [ProcessSample] = everyone, rates: [Int32: Double] = rates, refresh: Bool = true
    ) async throws -> SystemHarness {
        let system = SystemHarness(processes: processes, rates: rates)
        try await system.harness.run("kill-process")
        if refresh { try await system.harness.refresh() }
        return system
    }

    @Test func opensWithMemoryAtOnceAndCPUHalfASecondLater() async throws {
        let system = try await opened(refresh: false)
        #expect(system.harness.sections.map(\.title) == ["Processes"])
        #expect(system.harness.sections.first?.showsCount == true)
        #expect(system.harness.page?.refreshAfter == .milliseconds(500))
        // No CPU figure yet, so the busiest-first order falls back to memory.
        #expect(
            system.harness.rows.map(\.title) == [
                "Example Browser", "Example Editor", "example-indexer", "example-helper",
            ])
        #expect(system.harness.rows.allSatisfy { $0.accessories.count == 1 })

        try await system.harness.refresh()
        #expect(
            system.harness.rows.map(\.title) == [
                "example-indexer", "Example Browser", "Example Editor", "example-helper",
            ])
        #expect(system.harness.rows.first?.accessories == [.text("80.0% CPU"), .text("90.0 MB")])
        #expect(system.harness.rows[1].accessories == [.text("25.0% CPU"), .text("1.46 GB")])
        #expect(system.harness.page?.refreshAfter == .seconds(2))
        #expect(system.processes.snapshotCount == 2)
    }

    @Test func eachRowShowsWhoItIs() async throws {
        let system = try await opened()
        let row = try #require(system.harness.rows.first { $0.title == "Example Editor" })
        #expect(row.subtitle == "PID 201")
        #expect(row.icon == .app(bundleID: "com.example.editor"))
        #expect(row.keywords == ["201", "com.example.editor"])
        #expect(row.memory == .never)
        let background = try #require(system.harness.rows.first { $0.title == "example-helper" })
        #expect(background.icon == .symbol("gearshape"))
    }

    @Test func theDropdownSortsByCPUMemoryOrName() async throws {
        let system = try await opened()
        #expect(system.harness.page?.dropdown?.options.map(\.title) == ["CPU", "Memory", "Name"])
        #expect(system.harness.page?.filter == "cpu")
        try await system.harness.setFilter("memory")
        #expect(
            system.harness.rows.map(\.title) == [
                "Example Browser", "Example Editor", "example-indexer", "example-helper",
            ])
        try await system.harness.setFilter("name")
        #expect(
            system.harness.rows.map(\.title) == [
                "Example Browser", "Example Editor", "example-helper", "example-indexer",
            ])
    }

    @Test func theSettingChoosesTheOrderTheListOpensIn() async throws {
        let system = SystemHarness(processes: everyone, rates: rates)
        system.settings[SystemSettings.processSort] = .name
        try await system.harness.run("kill-process")
        #expect(system.harness.page?.filter == "name")
        #expect(system.harness.rows.first?.title == "Example Browser")
    }

    @Test func searchingKeepsTheOrder() async throws {
        let system = try await opened()
        try await system.harness.setQuery("example")
        #expect(system.harness.rows.first?.title == "example-indexer")
        try await system.harness.setQuery("203")
        #expect(system.harness.rows.map(\.title) == ["example-indexer"])
    }

    @Test func refreshesFollowProcessesThatStartAndEnd() async throws {
        let system = try await opened()
        system.processes.exit(204)
        system.processes.launch(SimulatedProcessTable.sample(205, "example-builder", memory: 50 << 20), rate: 1.5)
        try await system.harness.refresh()
        #expect(system.harness.rows.map(\.title).contains("example-helper") == false)
        // New since the last sample, so its CPU shows from the next refresh on.
        let builder = try #require(system.harness.rows.first { $0.title == "example-builder" })
        #expect(builder.accessories == [.text("50.0 MB")])
        try await system.harness.refresh()
        #expect(system.harness.rows.first?.title == "example-builder")
        #expect(system.harness.rows.first?.accessories.first == .text("150.0% CPU"))
    }

    @Test func neverOffersThisAppOrTheSessionsOwnProcesses() async throws {
        let protected = [
            SimulatedProcessTable.sample(99, "Launcher Under Test", app: "com.example.launcher"),
            SimulatedProcessTable.sample(150, "Another Copy", app: Brand.bundleID),
            SimulatedProcessTable.sample(1, "launchd"),
            SimulatedProcessTable.sample(151, "loginwindow"),
            SimulatedProcessTable.sample(152, "WindowServer"),
            SimulatedProcessTable.sample(153, "cfprefsd"),
        ]
        let system = try await opened(everyone + protected)
        #expect(system.harness.rows.count == everyone.count)
        #expect(system.harness.issues.isEmpty)
    }

    @Test func backgroundProcessesCanBeHiddenWhileTheListIsOpen() async throws {
        let system = try await opened()
        system.settings[SystemSettings.showsBackgroundProcesses] = false
        try await system.harness.settle()
        #expect(system.harness.rows.map(\.title) == ["Example Browser", "Example Editor"])
    }

    @Test func theRefreshIntervalFollowsTheSetting() async throws {
        let system = try await opened()
        system.settings[SystemSettings.processRefresh] = .fiveSeconds
        try await system.harness.settle()
        #expect(system.harness.page?.refreshAfter == .seconds(5))
    }

    @Test func quitAsksFirstThenAsksTheProcessToStop() async throws {
        let system = try await opened()
        try system.harness.select(title: "example-indexer")
        #expect(system.harness.actions().map(\.id) == ["quit", "force-quit", "copy-pid", "reveal", "refresh"])
        let outcome = try await system.harness.performPrimary()
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Quit example-indexer?")
        #expect(confirmation.message == "The process is asked to stop, and gets a moment to finish its work.")
        #expect(confirmation.confirmTitle == "Quit")
        #expect(outcome.kind == .keepOpen)
        #expect(system.processes.requests == [.quit(pid: 203)])
        #expect(system.harness.toasts.map(\.title) == ["Asked example-indexer to Quit"])
        #expect(!system.harness.rows.map(\.title).contains("example-indexer"), "the page reloaded")
        #expect(system.harness.issues.isEmpty, "after the page and its actions were shown")
    }

    @Test func quittingAnAppMentionsSaving() async throws {
        let system = try await opened()
        try system.harness.select(title: "Example Editor")
        try await system.harness.perform("quit")
        #expect(system.harness.confirmations.first?.message == "The app may ask you to save changes first.")
    }

    @Test func forceQuitAsksInRedAndEndsTheProcess() async throws {
        let system = try await opened()
        try system.harness.select(title: "Example Browser")
        let action = try #require(system.harness.actions().first { $0.id == "force-quit" })
        #expect(action.style == .destructive)
        #expect(action.shortcut == KeyCombo(.q, [.control, .option, .shift]))
        try await system.harness.perform("force-quit")
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == "Force quit Example Browser?")
        #expect(confirmation.message == "Example Browser stops at once. Anything it has not saved is lost.")
        #expect(confirmation.isDestructive)
        #expect(system.processes.requests == [.forceQuit(pid: 202)])
        #expect(system.harness.toasts.map(\.title) == ["Forced Example Browser to Quit"])
    }

    @Test func decliningQuitsNothing() async throws {
        let system = try await opened()
        system.harness.confirmationAnswer = false
        try system.harness.select(title: "Example Editor")
        try await system.harness.perform("quit")
        try await system.harness.perform("force-quit")
        #expect(system.processes.requests.isEmpty)
        #expect(system.harness.confirmations.count == 2)
    }

    @Test func aProcessThatAlreadyQuitSaysSo() async throws {
        let system = try await opened()
        try system.harness.select(title: "example-helper")
        system.processes.exit(204)
        system.harness.throwsActionErrors = false
        try await system.harness.perform("quit")
        #expect(system.harness.toasts.map(\.title) == ["example-helper Has Already Quit"])
        #expect(system.processes.requests.isEmpty)
    }

    @Test func aReusedPIDIsNeverQuit() async throws {
        let system = try await opened()
        try system.harness.select(title: "example-helper")
        system.processes.exit(204)
        system.processes.launch(SimulatedProcessTable.sample(204, "example-other", startTime: 42))
        system.harness.throwsActionErrors = false
        try await system.harness.perform("force-quit")
        #expect(system.processes.requests.isEmpty)
        #expect(system.harness.toasts.map(\.title) == ["example-helper Has Already Quit"])
    }

    @Test func copiesTheProcessID() async throws {
        let system = try await opened()
        try system.harness.select(title: "Example Editor")
        try await system.harness.perform("copy-pid")
        #expect(system.fakes.pasteboard.copiedTexts == ["201"])
        #expect(system.harness.huds == ["Copied Process ID"])
    }

    @Test func actionsComeFromThePayloadAlone() async throws {
        let system = try await opened()
        let shown = try #require(system.harness.rows.first)
        let bare = Row(id: shown.id, title: "", payload: shown.payload)
        guard case .list(let list) = try #require(system.harness.page).page else {
            Issue.record("not a list page")
            return
        }
        let source = list.source
        #expect(source.actions(for: bare).map(\.id) == ["quit", "force-quit", "copy-pid", "reveal", "refresh"])
        let protectedRow = Row(
            id: ItemID("process", "151-1"), title: "",
            payload: Payload(SimulatedProcessTable.sample(151, "loginwindow").identity))
        #expect(source.actions(for: protectedRow).map(\.id) == ["refresh"])
    }

    @Test func showsAnEmptyStateWhenNothingIsLeft() async throws {
        let system = try await opened([])
        #expect(system.harness.rows.isEmpty)
        #expect(system.harness.page?.emptyState?.title == "No Processes")
    }
}

@Suite("Process arithmetic", .timeLimit(.minutes(1)))
struct ProcessMathTests {
    private static func sample(_ pid: Int32, cpu: UInt64, start: UInt64 = 1, memory: UInt64 = 0, name: String = "p")
        -> ProcessSample
    {
        var sample = SimulatedProcessTable.sample(pid, name, memory: memory, startTime: start)
        sample.cpuTime = cpu
        return sample
    }

    @Test func cpuIsTheShareOfTheTimeBetweenSamples() {
        let before = Self.sample(5, cpu: 1_000_000_000)
        let now = Self.sample(5, cpu: 1_500_000_000)
        #expect(ProcessRows.cpuPercent(now, before: before, elapsed: 1_000_000_000) == 50)
        #expect(ProcessRows.cpuPercent(now, before: before, elapsed: 250_000_000) == 200, "several threads")
        #expect(ProcessRows.cpuPercent(now, before: nil, elapsed: 1_000_000_000) == nil)
        #expect(ProcessRows.cpuPercent(now, before: before, elapsed: 0) == nil)
        #expect(ProcessRows.cpuPercent(now, before: Self.sample(5, cpu: 0, start: 2), elapsed: 1) == nil, "PID reused")
        #expect(ProcessRows.cpuPercent(before, before: now, elapsed: 1) == nil, "a counter that went back")
    }

    @Test func tiesFallBackToNameThenPID() {
        let entries = [
            ProcessEntry(sample: Self.sample(9, cpu: 0, name: "item 10"), cpu: 1),
            ProcessEntry(sample: Self.sample(8, cpu: 0, name: "item 2"), cpu: 1),
            ProcessEntry(sample: Self.sample(7, cpu: 0, name: "item 2"), cpu: 1),
        ]
        #expect(ProcessRows.sorted(entries, by: .cpu).map(\.sample.pid) == [7, 8, 9])
        #expect(ProcessRows.sorted(entries, by: .name).map(\.sample.pid) == [7, 8, 9])
    }

    @Test func formatsLikeActivityMonitor() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(Strings.Processes.cpu(12.34, locale: locale) == "12.3% CPU")
        #expect(Strings.Processes.memory(245 << 20, locale: locale) == "245.0 MB")
        #expect(Strings.Processes.memory(1_300 << 20, locale: locale) == "1.27 GB")
        #expect(Strings.Processes.memory(512 << 10, locale: locale) == "0.5 MB")
    }

    @Test func protectsTheSession() {
        #expect(ProcessPolicy.isProtected(pid: 0, name: "kernel_task", path: nil, bundleID: nil, ownPID: 99))
        #expect(
            ProcessPolicy.isProtected(
                pid: 500, name: "x", path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                bundleID: nil, ownPID: 99))
        #expect(ProcessPolicy.isProtected(pid: 99, name: "anything", path: nil, bundleID: nil, ownPID: 99))
        #expect(ProcessPolicy.isProtected(pid: 500, name: "copy", path: nil, bundleID: Brand.bundleID, ownPID: 99))
        #expect(!ProcessPolicy.isProtected(pid: 500, name: "Dock", path: nil, bundleID: "com.apple.dock", ownPID: 99))
        #expect(
            !ProcessPolicy.isProtected(pid: 500, name: "Finder", path: nil, bundleID: "com.apple.finder", ownPID: 99))
    }

    @Test func convertsMachTimeToNanoseconds() {
        #expect(LiveProcessTable.nanoseconds(3, mach_timebase_info_data_t(numer: 125, denom: 3)) == 125)
        #expect(LiveProcessTable.nanoseconds(7, mach_timebase_info_data_t(numer: 1, denom: 1)) == 7)
    }
}
