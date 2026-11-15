import CoreAudio
import Foundation
import Kit
import KitHosting
import KitTesting
import Testing

@testable import Platform

@Suite(.timeLimit(.minutes(1))) struct SystemContextTests {
    @Test func changesAreToldOnlyWhenTheContextDiffers() async {
        let center = SystemContextCenter(SystemContext(frontmostBundleID: "com.example.editor", displayCount: 1))
        var changes = center.changes().makeAsyncIterator()
        center.update { $0.displayCount = 1 }  // the same: nothing told
        center.update { $0.onBattery = true }
        center.update { $0.audioRoute = .headphones }
        let first = await changes.next()
        #expect(first?.onBattery == true && first?.audioRoute == .unknown)
        #expect(await changes.next()?.audioRoute == .headphones)
        #expect(center.current().frontmostBundleID == "com.example.editor")
    }

    @Test func sessionStartsAreStreamedAndStreamsEndWithTheirConsumer() async {
        let center = SystemContextCenter()
        let clock = FakeClock()
        var starts = center.sessionStarts().makeAsyncIterator()
        center.sessionStarted(at: clock.now)
        #expect(await starts.next() == clock.now)

        let stream = center.changes()
        #expect(center.listenerCount == 2)
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await boundedValue(of: consumer)
        #expect(center.listenerCount == 1)
    }

    @Test func outputDevicesMapToRoutes() {
        let headphones = SystemReadings.headphonesDataSource
        #expect(SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .builtIn)
        #expect(
            SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: headphones)
                == .headphones)
        #expect(SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .bluetooth)
        #expect(
            SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil) == .bluetooth)
        #expect(SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil) == .external)
        #expect(SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeUSB, dataSource: nil) == .external)
        #expect(SystemReadings.audioRoute(transport: kAudioDeviceTransportTypeUnknown, dataSource: nil) == .unknown)
    }

    /// Reads power, displays and audio once and listens briefly. Read-only: nothing here prompts.
    @Test func theMonitorReadsTheMacAndFollowsTheFrontmostApp() async throws {
        let center = SystemContextCenter()
        let tracker = FrontmostTracker(ownProcessID: 4242, ownBundleID: "com.example.self")
        let monitor = SystemContextMonitor(center: center, frontmost: tracker, clock: FakeClock())
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.isRunning)
        #expect(center.current().displayCount >= 1)
        #expect(center.current().isFocusOn == false)

        tracker.activated(AppInfo(bundleID: "com.example.browser", name: "Browser"), processID: 100)
        try await waitUntil { center.current().frontmostBundleID == "com.example.browser" }
        monitor.stop()
        #expect(!monitor.isRunning)
    }
}

extension SystemContextTests {
    /// Found by measuring: the first CoreAudio read in a process waited 35 to 39 ms, and the
    /// monitor made it on the main thread at launch. Audio is now read on a queue of its own.
    @Test func theMonitorNeverReadsAudioOnTheMainThread() async throws {
        let center = SystemContextCenter()
        let tracker = FrontmostTracker(ownProcessID: 4242, ownBundleID: "com.example.self")
        let reads = Locked<[Bool]>([])
        let monitor = SystemContextMonitor(center: center, frontmost: tracker, clock: FakeClock()) {
            reads.withLock { $0.append(Thread.isMainThread) }
            return .headphones
        }
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil { center.current().audioRoute == .headphones }
        #expect(!reads.value.isEmpty)
        #expect(!reads.value.contains(true))
    }

    /// Found in review: a monitor released without stop() left the frontmost stream open and the
    /// power source pointing at freed memory.
    @Test func aMonitorReleasedWithoutStopStopsListening() async throws {
        let center = SystemContextCenter()
        let tracker = FrontmostTracker(ownProcessID: 4242, ownBundleID: "com.example.self")
        var monitor: SystemContextMonitor? = SystemContextMonitor(
            center: center, frontmost: tracker, clock: FakeClock())
        monitor?.start()
        #expect(tracker.listenerCount == 1)
        monitor = nil
        try await waitUntil { tracker.listenerCount == 0 }
        tracker.activated(AppInfo(bundleID: "com.example.browser", name: "Browser"), processID: 100)
        try await Task.sleep(for: .milliseconds(20))
        #expect(center.current().frontmostBundleID != "com.example.browser")
        withExtendedLifetime(monitor) {}
    }
}

@Suite(.timeLimit(.minutes(1))) struct PlatformServicesTests {
    /// Outside `live` nothing reaches the real Mac.
    @Test func aScenarioGetsServicesThatTouchNothing() async throws {
        let root = TemporaryFolder()
        let platform = PlatformServices(.init(environment: .scenario, dataRoot: root.url))
        platform.start()
        defer { platform.stop() }

        platform.settings.set(.bool(true), for: "sample.flag")
        #expect(platform.settings.storage(for: "sample.flag") == .bool(true))
        #expect(platform.storage.homeDirectory == root.url.appending(path: "Home/"))
        try await platform.secrets.setSecret("synthetic", for: "sample.key")
        #expect(try await platform.secrets.secret(for: "sample.key") == "synthetic")

        await #expect(throws: PlatformServiceError.unavailable(.scenario)) {
            try await platform.http.send(HTTPRequest(URL(string: "https://example.com")!))
        }
        await #expect(throws: ProcessError.self) {
            try await platform.processes.run(ProcessRequest(executable: URL(filePath: "/bin/echo")))
        }
        await #expect(throws: PlatformServiceError.self) {
            try await platform.workspace.open(URL(string: "https://example.com")!)
        }
        #expect(await platform.fileDialogs.chooseFiles(OpenDialogRequest()).isEmpty)
        #expect(platform.permissions.status(of: .fullDiskAccess) == .granted)
        #expect(await platform.permissions.request(.accessibility) == .granted)
        try platform.hotkeys.register(KeyCombo(.space, .option), id: "launcher") {}
        #expect(platform.hotkeys.registered.count == 1)
        #expect(platform.systemContext.current().frontmostBundleID == "com.example.editor")
        try platform.loginItem.setEnabled(true)
        #expect(platform.loginItem.isEnabled)
        #expect(platform.workspace.catalog.folders.isEmpty)

        // The pasteboard is a private one, and a paste sends no keystroke.
        try await platform.pasteboard.paste("synthetic")
        #expect(await platform.pasteboard.read()?.plainText == "synthetic")
        // A scenario can play another app copying, which the pasteboard then reports.
        let entries = platform.pasteboard.entries()
        await platform.copyAsAnotherApp("copied elsewhere")
        var iterator = entries.makeAsyncIterator()
        #expect(await iterator.next()?.plainText == "copied elsewhere")
        #expect(await platform.selection.currentSelection() == nil)
        #expect(
            await platform.textExpansion.start(keywords: [";x"], options: ExpansionOptions()) { _ in .ignore }
                == .running)
        await platform.textExpansion.stop()
        // App icons are generated, never the user's.
        let icon = Icon.app(bundleID: "com.example.app")
        _ = platform.icons.image(for: icon, size: IconSize(points: 16, scale: 2), isDark: false)
        _ = try await loaded { platform.icons.image(for: icon, size: IconSize(points: 16, scale: 2), isDark: false) }

        let fakes = FakeServices()
        let services = platform.services(usage: fakes.usage, fuzzyIndex: fakes.fuzzyIndex)
        let context = FeatureContext(featureID: "sample", environment: .scenario, services: services)
        context.settings[SettingKey("count", default: 0)] = 3
        #expect(platform.settings.storage(for: "sample.count") == .int(3))
        #expect(context.storage.dataDirectory == root.url.appending(path: "Features/sample/"))
        withExtendedLifetime(root) {}
    }
}
