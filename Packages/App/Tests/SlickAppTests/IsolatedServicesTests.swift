import Foundation
import Host
import Kit
import KitTesting
import Platform
import Testing

@testable import ColorTools
@testable import MarkdownNotes
@testable import MusicControls
@testable import ShellCommands
@testable import SlickApp
@testable import TranslateCommands

/// Outside the live launcher, the five features that reach real things on the Mac get their
/// simulated services. Shell starts no process, Colors shows no sampler, Translate never calls the
/// Translation framework, Media Controls sends no Apple Event and reads no running apps, and Notes
/// works only inside the run's own data folder.
///
/// Each feature's test builds the launcher as scenarios, the selftest and the bench build it, then
/// asks the context the app gave the feature for each of the feature's own services, as the feature
/// does in `init(context:)`. Where the feature keeps the service where a test can read it, the test
/// reads that too. A check first makes sure the run is not live, so a wrong run environment fails
/// before any live service is made. No service is ever called, except the confined disk of Notes,
/// which is asked to list a folder outside the run.
@Suite("Isolated services", .serialized, .timeLimit(.minutes(2)))
struct IsolatedServicesTests {
    /// The ways the app runs outside the live launcher.
    enum Mode: String, CaseIterable, CustomTestStringConvertible {
        case scenario, selftest, bench

        var testDescription: String { rawValue }
    }

    // MARK: One test per feature

    @Test(arguments: Mode.allCases)
    func shellRunsItsSimulatedShell(_ mode: Mode) async throws {
        try await withFeature("shell", in: mode) { context, feature, _ in
            #expect(feature is ShellFeature)
            #expect(Self.liveServices(shell: context).isEmpty)
        }
    }

    @Test(arguments: Mode.allCases)
    func colorsNeverShowsTheSystemSampler(_ mode: Mode) async throws {
        try await withFeature("colors", in: mode) { context, feature, _ in
            let colors = try #require(feature as? ColorsFeature)
            #expect(colors.sampler is SimulatedColorSampler)
            #expect(Self.liveServices(colors: context).isEmpty)
        }
    }

    @Test(arguments: Mode.allCases)
    func translateNeverCallsTheTranslationFramework(_ mode: Mode) async throws {
        try await withFeature("translate", in: mode) { context, feature, _ in
            let translate = try #require(feature as? TranslateFeature)
            #expect(translate.translator.engine is SimulatedTranslation)
            #expect(Self.liveServices(translate: context).isEmpty)
        }
    }

    @Test(arguments: Mode.allCases)
    func mediaControlsNeverReachesARealPlayer(_ mode: Mode) async throws {
        try await withFeature("media", in: mode) { context, feature, _ in
            let media = try #require(feature as? MediaControlsFeature)
            #expect(media.players is SimulatedPlayers)
            #expect(Self.liveServices(media: context).isEmpty)
        }
    }

    @Test(arguments: Mode.allCases)
    func notesWorksOnlyInsideTheRunsDataFolder(_ mode: Mode) async throws {
        try await withFeature("notes", in: mode) { context, feature, dataRoot in
            let notes = try #require(feature as? NotesFeature)
            #expect(Self.liveServices(notes: context, dataRoot: dataRoot).isEmpty)
            let folder = NoteLibrary.defaultFolderURL(for: context)
            #expect(Self.isInside(folder, dataRoot), "\(folder.path)")
            #expect(Self.isInside(notes.library.index.folder.url, dataRoot), "\(notes.library.index.folder.url.path)")

            // A folder outside the run is refused before it is opened.
            let outside = FileManager.default.temporaryDirectory.appending(
                path: "app-isolation-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let disk = context.service(NoteDiskKey.self)
            #expect(throws: DiskError.outsideRun) { try disk.list(outside, limit: 1) }
        }
    }

    /// The switch that turns Spotlight's shortcuts off reaches the Mac only in the live launcher.
    /// Every other run gets the inert one over the inert hotkey system, and the Kit service the
    /// features and the launcher hotkey use is that hotkey center.
    @Test(arguments: Mode.allCases)
    func theSpotlightSwitchIsNeverTheLiveOne(_ mode: Mode) async throws {
        try await withFeature("shell", in: mode) { context, _, _ in
            #expect(context.hotkeys is HotkeyCenter)
            let center = try #require(context.hotkeys as? HotkeyCenter)
            #expect(Self.liveServices(hotkeys: center).isEmpty)
        }
    }

    /// The check above reports a live switch, made here and never called.
    @Test func theSwitchCheckReportsALiveSwitch() {
        let live = HotkeyCenter(
            system: InertHotkeySystem(), shortcuts: LiveSpotlightShortcutSwitch(processes: FakeProcesses()))
        #expect(Self.liveServices(hotkeys: live) == ["spotlight switch"])
        #expect(Self.liveServices(hotkeys: HotkeyCenter(system: CarbonHotkeySystem())) == ["hotkey system"])
    }

    static func liveServices(hotkeys: HotkeyCenter) -> [String] {
        var found: [String] = []
        if !(hotkeys.system is InertHotkeySystem) { found.append("hotkey system") }
        if let shortcuts = hotkeys.shortcuts, !(shortcuts is InertSpotlightShortcutSwitch) {
            found.append("spotlight switch")
        }
        return found
    }

    // MARK: The checks catch a live service

    /// The checks the tests above rely on report a live run, and a context that would hand out a
    /// live service, without calling that service.
    @Test func theChecksReportALiveServiceWithoutCallingIt() throws {
        let dataRoot = FileManager.default.temporaryDirectory.appending(path: "app-isolation-\(UUID().uuidString)")
        let live = FakeServices().context(featureID: "colors", environment: .live)
        #expect(Self.liveServices(shell: live) == ["a live run"])
        #expect(Self.liveServices(colors: live) == ["a live run"])
        #expect(Self.liveServices(translate: live) == ["a live run"])
        #expect(Self.liveServices(media: live) == ["a live run"])
        #expect(Self.liveServices(notes: live, dataRoot: dataRoot) == ["a live run"])

        // Each live implementation is made here and never called.
        let fakes = FakeServices()
        fakes.override(ShellSystemKey.self, with: LiveShellSystem())
        fakes.override(ShellProcessesKey.self, with: fakes.processes)
        fakes.override(ColorSamplerKey.self, with: SystemColorSampler())
        fakes.override(TranslationEngineKey.self, with: SystemTranslation())
        fakes.override(PlayerServiceKey.self, with: LivePlayers())
        fakes.override(NoteDiskKey.self, with: PosixNoteDisk(roots: nil))
        let context = fakes.context(featureID: "colors", environment: .selftest)
        #expect(Self.liveServices(shell: context).count == 2)
        #expect(Self.liveServices(colors: context).count == 1)
        #expect(Self.liveServices(translate: context).count == 1)
        #expect(Self.liveServices(media: context).count == 1)
        #expect(Self.liveServices(notes: context, dataRoot: dataRoot).count == 1)

        // A disk confined to the wrong folders is reported too.
        let elsewhere = FakeServices()
        elsewhere.override(NoteDiskKey.self, with: PosixNoteDisk(roots: [URL(filePath: "/")]))
        let confinedElsewhere = elsewhere.context(featureID: "notes", environment: .selftest)
        #expect(Self.liveServices(notes: confinedElsewhere, dataRoot: dataRoot).count == 1)
    }

    // MARK: Checks

    /// Each service of Shell the context would hand out that is not the simulated one.
    static func liveServices(shell context: FeatureContext) -> [String] {
        guard !context.environment.touchesRealSystem else { return ["a live run"] }
        var found: [String] = []
        if !(context.service(ShellProcessesKey.self) is SimulatedShellProcesses) { found.append("processes") }
        if !(context.service(ShellSystemKey.self) is SimulatedShellSystem) { found.append("shell lookups") }
        return found
    }

    static func liveServices(colors context: FeatureContext) -> [String] {
        guard !context.environment.touchesRealSystem else { return ["a live run"] }
        return context.service(ColorSamplerKey.self) is SimulatedColorSampler ? [] : ["sampler"]
    }

    static func liveServices(translate context: FeatureContext) -> [String] {
        guard !context.environment.touchesRealSystem else { return ["a live run"] }
        return context.service(TranslationEngineKey.self) is SimulatedTranslation ? [] : ["engine"]
    }

    static func liveServices(media context: FeatureContext) -> [String] {
        guard !context.environment.touchesRealSystem else { return ["a live run"] }
        return context.service(PlayerServiceKey.self) is SimulatedPlayers ? [] : ["players"]
    }

    /// Notes' disk is the one service that is real in every run. Outside the live launcher it must
    /// be confined, and only to folders inside the run's data folder.
    static func liveServices(notes context: FeatureContext, dataRoot: URL) -> [String] {
        guard !context.environment.touchesRealSystem else { return ["a live run"] }
        guard let disk = context.service(NoteDiskKey.self) as? PosixNoteDisk, let roots = disk.roots, !roots.isEmpty,
            roots.allSatisfy({ isInside(URL(filePath: $0), dataRoot) })
        else { return ["disk"] }
        return []
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = PosixNoteDisk.comparablePath(url)
        let root = PosixNoteDisk.comparablePath(folder)
        return path == root || path.hasPrefix(root + "/")
    }

    // MARK: Building the launcher

    /// The launcher as `mode` builds it, over a fresh temporary folder, with every feature
    /// registered and activated and no panel. Runs `check` with the context the app gave the
    /// feature, the feature itself and the data folder, then shuts the launcher down.
    func withFeature(
        _ id: String, in mode: Mode, _ check: (FeatureContext, any Feature, URL) async throws -> Void
    ) async throws {
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "app-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        var configuration: Assembly.Configuration
        switch mode {
        case .scenario:
            let file = ScenarioMode.File(name: "isolation", timeLimit: 30, items: [])
            configuration = try ScenarioMode.configuration(for: file, dataRoot: dataRoot)
        case .selftest:
            configuration = SelfTest.configuration(dataRoot: dataRoot)
        case .bench:
            configuration = BenchMode.configuration(dataRoot: dataRoot, size: 10)
        }
        configuration.makesPanel = false
        try #require(!configuration.environment.touchesRealSystem, "the \(mode) run is live")
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: false)
        let context = assembly.runtime.context(for: id)
        let feature = assembly.runtime.instance(id)
        do {
            try #require(context.featureID == id, "the app did not register \(id)")
            try #require(!context.environment.touchesRealSystem, "\(id) runs live in the \(mode) run")
            try await check(context, try #require(feature), dataRoot)
        } catch {
            await assembly.shutdown()
            throw error
        }
        await assembly.shutdown()
    }
}
