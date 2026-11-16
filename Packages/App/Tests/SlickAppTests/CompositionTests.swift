import Foundation
import Host
import Kit
import KitHosting
import KitTesting
import Root
import SettingsUI
import Testing

@testable import SlickApp

/// The whole launcher, built in the selftest environment over a temporary folder. No panel is
/// shown: these tests never summon.
@Suite("Composition")
struct CompositionTests {
    /// A temporary data folder, deleted by ``remove()``.
    struct Folder {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func theSelftestCompositionPasses() async {
        let folder = Folder()
        defer { folder.remove() }
        let report = await SelfTest.checkComposition(dataRoot: folder.url)
        #expect(report.passed, "\(report.failures)")
        #expect(report.facts.contains("features=\(Features.types.count)"))
    }

    @Test func everyPartIsConnected() async {
        let folder = Folder()
        defer { folder.remove() }
        let hotkeys = FakeHotkeys()
        let assembly = Assembly(
            .init(
                environment: .selftest, dataRoot: folder.url, rootStorage: .inMemory, hotkeys: hotkeys,
                makesPanel: false))
        await assembly.start(prewarm: false)
        _ = await SelfTest.within(.seconds(20)) { await assembly.ready() }

        // Root's services reach the features.
        let usage = assembly.services.usage
        usage.recordUse(of: ItemID("test", "item"))
        #expect(assembly.root.usage.useCount(of: ItemID("test", "item")) == 1)
        let index = await assembly.services.fuzzyIndex.makeIndex([FuzzyEntry(title: "Text Editor")])
        #expect(index.search("tex", limit: 5).first?.index == 0)
        // Host searches with no limit; Root's index must not size a buffer by it.
        #expect(index.search("tex", limit: .max).count == 1)

        // Every feature registered and the Apps feature's synthetic apps are in root search.
        #expect(assembly.runtime.features.map(\.id) == Features.types.map { $0.manifest.id })
        let snapshot = assembly.root.update(query: "text editor")
        #expect(snapshot.rows.first?.id == ItemID("app", "com.example.text-editor"))
        assembly.root.end()

        // The launcher hotkey goes through the hotkey service the composition was given.
        #expect(hotkeys.registered[LauncherHotkey.bindingID] == KeyCombo(.space, .command))
        assembly.general[HostSettings.launcherHotkey] = KeyCombo(.k, [.command, .option])
        try? await waitUntil { hotkeys.registered[LauncherHotkey.bindingID] == KeyCombo(.k, [.command, .option]) }

        // Settings would open; outside live nothing shows.
        assembly.settings.open(.learning)
        #expect(assembly.settings.requests == [.pane(.learning)])

        await assembly.shutdown()
        #expect(hotkeys.registered[LauncherHotkey.bindingID] == nil)
    }

    @Test func linksAreCheckedAgainstWhatExists() async throws {
        let folder = Folder()
        defer { folder.remove() }
        let assembly = Assembly(
            .init(environment: .selftest, dataRoot: folder.url, rootStorage: .inMemory, makesPanel: false))
        await assembly.start(prewarm: false)
        let links = assembly.links
        func open(_ rest: String) throws -> DeepLinkRouter.Outcome {
            links.handle(try #require(URL(string: Brand.urlScheme + "://" + rest)))
        }

        #expect(try open("search?q=notes") == .openedLauncher(query: "notes"))
        #expect(try open("settings/learning") == .openedSettings(.learning))
        #expect(try open("settings") == .openedSettings(nil))
        #expect(try open("settings/nothing") == .refused(.unknownPane))
        #expect(try open("settings/features/apps") == .openedFeatureSettings("apps"))
        #expect(try open("settings/features/missing") == .refused(.unknownFeature))
        #expect(try open("commands/apps/missing") == .refused(.unknownCommand))
        #expect(try open("commands/missing/running") == .refused(.unknownCommand))
        #expect(try open("commands/apps/running?query=x") == .refused(.unknownArgument("query")))
        #expect(try open("commands/apps/running%3Fx") == .refused(.badCommandID))

        // A command asks first, every time, until the user always allows it.
        let running = ItemID.command(feature: "apps", command: "running")
        #expect(try open("commands/apps/running") == .asked(running))
        #expect(try open("commands/apps/running") == .asked(running))
        let runningEntry = try #require(assembly.runtime.command(running))
        links.allowAlways(runningEntry, arguments: [:])
        #expect(
            links.alwaysAllowed == [
                LinkAllowances.Entry(command: running, arguments: [:], title: "Running Applications")
            ])
        #expect(try open("commands/apps/running") == .ran(running))

        // A command that is switched off does not run, even when allowed.
        assembly.runtime.preferences.setEnabled(false, command: running)
        #expect(try open("commands/apps/running") == .refused(.commandOff))

        // A command that keeps out of deep links is refused before the page that asks, and even
        // after Always Allow. Snippets' Fill In Snippet is hidden and pastes at once.
        let fill = ItemID.command(feature: "snippets", command: "fill")
        #expect(assembly.runtime.command(fill)?.command.allowsDeepLinks == false)
        #expect(try open("commands/snippets/fill") == .refused(.commandRefusesLinks))
        links.allowAlways(try #require(assembly.runtime.command(fill)), arguments: [:])
        #expect(try open("commands/snippets/fill") == .refused(.commandRefusesLinks))
        #expect(!links.outcomes.contains(.asked(fill)))
        #expect(!links.outcomes.contains(.ran(fill)))

        await assembly.shutdown()
    }

    /// An allowance whose command is gone, or has another title now, is dropped before the next
    /// command link, so a script saved later where an allowed one was does not inherit it.
    @Test func allowancesForGoneOrRenamedCommandsAreDropped() async throws {
        let folder = Folder()
        defer { folder.remove() }
        let assembly = Assembly(
            .init(environment: .selftest, dataRoot: folder.url, rootStorage: .inMemory, makesPanel: false))
        await assembly.start(prewarm: false)
        let links = assembly.links
        let store = LinkAllowances.settings(assembly.services.settings)
        let running = ItemID.command(feature: "apps", command: "running")
        let kept = LinkAllowances.Entry(command: running, arguments: [:], title: "Running Applications")
        let renamed = LinkAllowances.Entry(command: running, arguments: ["x": "1"], title: "Old Title")
        let gone = LinkAllowances.Entry(
            command: .command(feature: "scripts", command: "removed"), arguments: [:], title: "Removed Script")
        for entry in [kept, renamed, gone] { LinkAllowances.add(entry, in: store) }

        let outcome = links.handle(try #require(URL(string: Brand.urlScheme + "://commands/apps/running")))
        #expect(outcome == .ran(running))
        #expect(links.alwaysAllowed == [kept])
        await assembly.shutdown()
    }

    @Test func forwardersAnswerBeforeRootIsConnected() async {
        let usage = LateUsageService()
        #expect(!usage.isConnected)
        usage.recordUse(of: ItemID("test", "x"))
        #expect(usage.useCount(of: ItemID("test", "x")) == 0)
        #expect(usage.recentlyUsed(namespace: "test", limit: 3).isEmpty)
        let index = LateFuzzyIndexService()
        let made = await index.makeIndex([FuzzyEntry(title: "A")])
        #expect(made.count == 1)
        #expect(made.search("a", limit: 1).isEmpty)
        let fake = FakeUsage(clock: FakeClock())
        usage.connect(fake)
        usage.recordUse(of: ItemID("test", "x"))
        #expect(usage.useCount(of: ItemID("test", "x")) == 1)
    }
}

/// A feature that provides clipboard history, as the clipboard feature will.
final class HistoryFeature: Feature {
    static let manifest = FeatureManifest(id: "history-test", name: "History Test", icon: .symbol("clock"))

    struct Reader: ClipboardHistoryReader {
        @concurrent func text(offset: Int) async -> String? {
            offset == 0 ? "from history" : nil
        }
    }

    init(context: FeatureContext) {}

    var provides: [ProvidedService] { [.clipboardHistory(Reader())] }
}

@Suite("Provided services")
struct ProvidedServiceTests {
    @Test func clipboardHistoryAnswersThePasteboardWhileItsFeatureIsOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "app-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var configuration = Assembly.Configuration(
            environment: .selftest, dataRoot: folder, rootStorage: .inMemory, makesPanel: false)
        // The real clipboard feature provides history too, and the first enabled provider wins.
        configuration.registrations = [FeatureRegistration(HistoryFeature.self)] + Features.registrations
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: false)
        #expect(assembly.hasHistoryReader)
        #expect(await assembly.services.pasteboard.recentText(offset: 0) == "from history")

        // With the test feature off, the clipboard feature's own history takes over while it is on.
        await assembly.runtime.preferences.setEnabled(false, feature: "history-test")
        await assembly.runtime.preferences.setEnabled(true, feature: "clipboard")
        // The switch reaches the pasteboard on the next directory change, so wait for it.
        var answer = await assembly.services.pasteboard.recentText(offset: 0)
        let deadline = ContinuousClock.now + .seconds(2)
        while answer == "from history", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            answer = await assembly.services.pasteboard.recentText(offset: 0)
        }
        #expect(answer != "from history")
        #expect(assembly.hasHistoryReader)
        await assembly.runtime.preferences.setEnabled(false, feature: "clipboard")
        try await waitUntil { !assembly.hasHistoryReader }
        await assembly.shutdown()
    }
}
