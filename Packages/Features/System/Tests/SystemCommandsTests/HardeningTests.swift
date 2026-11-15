import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

/// Guards that keep the live services from doing harm, checked through the pure rules they use.
@Suite("Safety", .timeLimit(.minutes(1)))
@MainActor
struct SafetyTests {
    private static let uid: uid_t = 501
    private static let helper = SimulatedProcessTable.sample(204, "example-helper").identity

    private static func current(
        name: String = "example-helper", path: String? = "/usr/local/libexec/example-helper", uid: uid_t = uid,
        startTime: UInt64? = nil, bundleID: String? = nil
    ) -> LiveProcessTable.Current {
        LiveProcessTable.Current(
            startTime: startTime ?? helper.startTime, uid: uid, name: name, path: path, bundleID: bundleID)
    }

    @Test func theLiveTableSignalsOnlyTheProcessTheRowNamed() {
        func refusal(_ process: ProcessIdentity, _ current: LiveProcessTable.Current?) -> SystemFailure? {
            LiveProcessTable.refusal(for: process, current: current, ownPID: 99, uid: Self.uid)
        }
        #expect(refusal(Self.helper, Self.current()) == nil)
        #expect(refusal(Self.helper, nil) == .notFound, "the process is gone")
        #expect(refusal(Self.helper, Self.current(startTime: 7)) == .notFound, "the PID now names another process")
        #expect(refusal(Self.helper, Self.current(uid: 0)) == .failed(code: EPERM), "another user's process")
        var own = Self.helper
        own.pid = 99
        #expect(refusal(own, Self.current()) == .protected)
        for pid: Int32 in [-1, 0, 1] {
            var low = Self.helper
            low.pid = pid
            #expect(refusal(low, Self.current()) == .protected, "PID \(pid)")
        }
    }

    @Test func aHarmlessPayloadNeverEndsAProtectedProcess() {
        func refusal(_ current: LiveProcessTable.Current) -> SystemFailure? {
            LiveProcessTable.refusal(for: Self.helper, current: current, ownPID: 99, uid: Self.uid)
        }
        #expect(refusal(Self.current(name: "loginwindow", path: nil)) == .protected)
        #expect(
            refusal(Self.current(name: "x", path: "/System/Library/PrivateFrameworks/Example/WindowServer"))
                == .protected)
        #expect(refusal(Self.current(bundleID: Brand.bundleID)) == .protected, "another copy of this app")
    }

    @Test func theSimulatedTableRefusesWhatTheLiveOneRefuses() async throws {
        let session = SimulatedProcessTable.sample(151, "loginwindow")
        let table = SimulatedProcessTable([session])
        await #expect(throws: SystemFailure.protected) { try await table.quit(session.identity) }
        // The same PID and start time behind a payload that names something harmless.
        var disguised = session.identity
        disguised.name = "example-helper"
        disguised.path = "/usr/local/libexec/example-helper"
        await #expect(throws: SystemFailure.protected) { try await table.forceQuit(disguised) }
        #expect(table.requests.isEmpty)
    }

    @Test func aProtectedProcessBehindAStaleRowSaysWhyAndSurvives() async throws {
        let session = SimulatedProcessTable.sample(151, "loginwindow")
        let system = SystemHarness(processes: [session])
        try await system.harness.run("kill-process")
        guard case .list(let list) = try #require(system.harness.page).page else {
            Issue.record("not a list page")
            return
        }
        var disguised = session.identity
        disguised.name = "example-helper"
        disguised.path = "/usr/local/libexec/example-helper"
        let row = Row(id: ItemID("process", "151-1"), title: "example-helper", payload: Payload(disguised))
        let quit = try #require(list.source.actions(for: row).first { $0.id == "quit" })
        system.harness.throwsActionErrors = false
        try await system.harness.perform(quit, row: row)
        #expect(system.processes.requests.isEmpty)
        #expect(system.harness.toasts.map(\.title) == ["Could Not Quit example-helper"])
        #expect(system.harness.toasts.first?.message == "macOS needs this process to keep your session running.")
    }

    @Test func everyRunOutsideTheAppGetsTheSimulatedServices() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let context = FakeServices().context(featureID: "system", environment: environment)
            #expect(context.service(PowerServiceKey.self) is SimulatedPower, "\(environment)")
            #expect(context.service(HousekeepingServiceKey.self) is SimulatedHousekeeping, "\(environment)")
            #expect(context.service(AppearanceServiceKey.self) is SimulatedAppearance, "\(environment)")
            #expect(context.service(SoundServiceKey.self) is SimulatedSound, "\(environment)")
            #expect(context.service(ProcessTableKey.self) is SimulatedProcessTable, "\(environment)")
        }
        let harness = FeatureHarness(SystemFeature.self)
        #expect(harness.feature.power is SimulatedPower, "a harness made without overrides")
        #expect(harness.feature.processes is SimulatedProcessTable)
    }

    @Test func activatingTheFeatureTouchesNothing() async throws {
        let system = SystemHarness(trashItems: 3, disks: [SystemHarness.drive], processes: [SystemHarness.sample])
        await system.harness.activate()
        try await system.harness.settle()
        await system.harness.deactivate()
        await system.harness.activate()
        #expect(system.power.requests.isEmpty)
        #expect(system.housekeeping.requests.isEmpty)
        #expect(system.processes.snapshotCount == 0)
        #expect(system.processes.requests.isEmpty)
        #expect(system.fakes.processes.runs.isEmpty)
        #expect(system.fakes.permissions.requests.isEmpty)
        #expect(system.fakes.hotkeys.registered.isEmpty)
        #expect(system.harness.huds.isEmpty && system.harness.toasts.isEmpty)
    }
}

@Suite("Odd input", .timeLimit(.minutes(1)))
@MainActor
struct OddInputTests {
    @Test(arguments: [
        ("\u{FF14}\u{FF10}", 0.4), ("\u{0664}\u{0660}", 0.4), ("\u{0664}\u{0660}\u{066A}", 0.4),
        ("\u{FF14}\u{FF10}\u{FF05}", 0.4), ("12\u{066B}5", 0.125), ("\u{200F}40", 0.4), ("\u{0967}\u{0966}\u{0966}", 1),
        (String(repeating: "0", count: 62) + "7", 0.07),
    ])
    func setVolumeReadsDigitsOfEveryScript(text: String, level: Double) {
        #expect(VolumeLevel.parse(text) == level)
    }

    @Test(arguments: [
        "\u{00B2}", "\u{216B}", "\u{0661}\u{0660}\u{0661}", String(repeating: "4", count: 10_000), "4\u{0000}0",
        "\u{1F50A}", "40 percent",
    ])
    func setVolumeRefusesLookalikes(text: String) {
        #expect(VolumeLevel.parse(text) == nil)
    }

    @Test func diskNamesMatchWithoutCaseWidthOrStraySpaces() {
        #expect(DiskNamePattern.matches("Example Backup", any: ["example backup"]))
        #expect(DiskNamePattern.matches("Example Backup", any: ["  Example Backup \n"]))
        #expect(DiskNamePattern.matches("Example\u{FF22}ackup", any: ["exampleBackup"]), "full-width letters")
        #expect(DiskNamePattern.matches("Caf\u{0065}\u{0301}", any: ["Caf\u{00E9}"]), "composed and decomposed")
        #expect(!DiskNamePattern.matches("Example Drive", any: ["", "   "]), "an empty name matches nothing")
    }

    @Test(arguments: [
        ("Backup*", "Backup 2026", true), ("Backup*", "Old Backup", false), ("*Backup", "Old Backup", true),
        ("Ex*Dr*", "Example Drive", true), ("Ex*Dr*", "Example Server", false), ("*", "Anything", true),
        ("Back*up", "Backup", true), ("a*a", "a", false), ("*ample*", "Example Drive", true),
        ("Example Drive*", "example drive", true),
    ])
    func neverEjectTakesWildcards(pattern: String, name: String, matches: Bool) {
        #expect(DiskNamePattern.matches(name, any: [pattern]) == matches)
    }

    @Test func aWildcardKeepsMatchingDisksMounted() async throws {
        let system = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        system.settings[SystemSettings.neverEject] = ["example b*"]
        try await system.harness.run("eject-all-disks")
        #expect(system.harness.confirmations.first?.message == "This ejects Example Drive.")
        #expect(system.housekeeping.disks == [SystemHarness.backup])

        let none = SystemHarness(disks: [SystemHarness.drive, SystemHarness.backup])
        none.settings[SystemSettings.neverEject] = ["*"]
        let outcome = try await none.harness.run("eject-all-disks")
        #expect(outcome.kind == .close(hud: "No Disks to Eject"))
        #expect(none.housekeeping.requests.isEmpty)
    }

    @Test func diskNamesOfEveryKindReadWell() async throws {
        let disks = [
            Disk(name: "\u{05D2}\u{05D9}\u{05D1}\u{05D5}\u{05D9}", path: "/Volumes/a", isNetwork: false),
            Disk(name: "\u{1F4BE} Example", path: "/Volumes/b", isNetwork: false),
            Disk(name: String(repeating: "x", count: 300), path: "/Volumes/c", isNetwork: false),
        ]
        let system = SystemHarness(disks: disks)
        try await system.harness.run("eject-all-disks")
        #expect(system.harness.confirmations.first?.title == "Eject 3 disks?")
        #expect(system.housekeeping.disks.isEmpty)
    }

    @Test func aBusyFinderSaysWhenTheChangeApplies() async throws {
        let system = SystemHarness()
        system.housekeeping.setFinderRestarts(false)
        try await system.harness.run("toggle-hidden-files")
        #expect(system.harness.isClosed, "the panel closed before Finder was asked to quit")
        #expect(system.harness.huds == ["Finder Shows Hidden Files the Next Time It Opens"])
        try await system.harness.run("toggle-hidden-files")
        #expect(system.harness.huds.last == "Finder Hides Hidden Files the Next Time It Opens")
    }

    @Test func processesWithoutAUsableNameStillReadWell() async throws {
        let unnamed = SimulatedProcessTable.sample(4_242, "")
        let multiline = SimulatedProcessTable.sample(4_243, "example\nworker\t2")
        let spaced = SimulatedProcessTable.sample(4_244, "  \u{0007}  ")
        let system = SystemHarness(processes: [unnamed, multiline, spaced])
        try await system.harness.run("kill-process")
        #expect(
            Set(system.harness.rows.map(\.title)) == ["Process 4242", "example worker 2", "Process 4244"])
        try system.harness.select(title: "Process 4242")
        try await system.harness.perform("quit")
        #expect(system.harness.confirmations.first?.title == "Quit Process 4242?")
        #expect(system.harness.issues.isEmpty)
    }

    @Test func showInFinderRevealsAnAppsBundleAndAToolsExecutable() async throws {
        let app = SimulatedProcessTable.sample(401, "Example Editor", app: "com.example.editor")
        let tool = SimulatedProcessTable.sample(402, "example-tool")
        let system = SystemHarness(processes: [app, tool])
        try await system.harness.run("kill-process")
        try system.harness.select(title: "Example Editor")
        try await system.harness.perform("reveal")
        try system.harness.select(title: "example-tool")
        try await system.harness.perform("reveal")
        #expect(
            system.fakes.workspace.revealed.map(\.path) == [
                "/Applications/Example Editor.app", "/usr/local/libexec/example-tool",
            ])
    }

    @Test func fiftyThousandProcessesSortAndBuild() async {
        let count = 50_000
        var processes: [ProcessSample] = []
        processes.reserveCapacity(count)
        for index in 0..<count {
            var sample = SimulatedProcessTable.sample(Int32(1_000 + index), "example-\(index)")
            sample.cpuTime = UInt64(index) * 1_000
            processes.append(sample)
        }
        let before = ProcessSnapshot(
            uptime: 1_000_000_000, ownPID: 99,
            processes: processes.map { sample in
                var earlier = sample
                earlier.cpuTime = 0
                return earlier
            })
        let after = ProcessSnapshot(uptime: 2_000_000_000, ownPID: 99, processes: processes)
        let rows = await ProcessRows.rows(
            after, previous: before, sort: .cpu, showsBackground: true, locale: Locale(identifier: "en_US_POSIX"))
        #expect(rows.count == count)
        #expect(rows.first?.title == "example-\(count - 1)")
        #expect(Set(rows.map(\.id)).count == count, "every row has its own ID")
    }

    @Test func aRefreshThatIsCancelledKeepsTheLastSample() async throws {
        let system = SystemHarness(processes: [SystemHarness.sample])
        let list = ProcessList(
            table: system.processes, settings: system.settings, locale: Locale(identifier: "en_US_POSIX"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await list.load(ListRequest())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        // The next load is the first one that counts, so it asks again soon for CPU.
        let result = try await list.load(ListRequest())
        #expect(result.refreshAfter == ProcessList.firstRefresh)
    }
}

extension SystemHarness {
    static let sample = SimulatedProcessTable.sample(301, "example-worker")
}
