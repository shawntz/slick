import Foundation
import Kit
import Synchronization

/// One fake for every service, sharing one ``FakeClock``. Pass ``services`` wherever Kit wants
/// ``Services``, and read the fakes to see what a feature did.
public final class FakeServices: Sendable {
    public let clock: FakeClock
    public let pasteboard: FakePasteboard
    public let workspace = FakeWorkspace()
    public let hotkeys = FakeHotkeys()
    public let permissions: FakePermissions
    public let processes = FakeProcesses()
    public let http = FakeHTTP()
    public let storage: FakeStorage
    public let settings = FakeSettings()
    public let secrets = FakeSecrets()
    public let usage: FakeUsage
    public let fuzzyIndex = FakeFuzzyIndexService()
    public let selection = FakeSelection()
    public let fileWatcher = FakeFileWatcher()
    public let fileDialogs = FakeFileDialogs()
    public let textExpansion = FakeTextExpansion()

    private let overrides = Mutex(ServiceOverrides())
    private let processReplacement = Mutex<(any ProcessService)?>(nil)

    /// - Parameters:
    ///   - clock: The clock every fake stamps time with.
    ///   - permissions: The status of every permission not set explicitly.
    ///   - storageRoot: Where ``FakeStorage`` keeps files. Defaults to a fresh temporary folder.
    public init(clock: FakeClock = FakeClock(), permissions: PermissionStatus = .granted, storageRoot: URL? = nil) {
        self.clock = clock
        self.pasteboard = FakePasteboard(clock: clock)
        self.permissions = FakePermissions(defaultStatus: permissions)
        self.storage = FakeStorage(root: storageRoot)
        self.usage = FakeUsage(clock: clock)
    }

    /// Makes `FeatureContext.service(_:)` return `value` for the key, so a feature's own service can
    /// be a test double. Set it before the feature is made.
    public func override<Key: FeatureServiceKey>(_ key: Key.Type, with value: Key.Value) {
        overrides.withLock { $0[key] = value }
    }

    /// Makes every context made from these fakes run processes through `service` instead of
    /// ``processes``, such as a wrapper that records cancellations and forwards to ``processes``.
    /// Set it before the feature is made: the feature's context and the harness's action contexts
    /// both get it.
    public func replaceProcesses(with service: any ProcessService) {
        processReplacement.withLock { $0 = service }
    }

    /// The fakes as Kit's service container.
    public var services: Services {
        Services(
            pasteboard: pasteboard, workspace: workspace, hotkeys: hotkeys, permissions: permissions,
            processes: processReplacement.withLock { $0 } ?? processes, http: http, storage: storage,
            settings: settings, secrets: secrets, clock: clock,
            usage: usage, fuzzyIndex: fuzzyIndex, selection: selection, fileWatcher: fileWatcher,
            fileDialogs: fileDialogs, textExpansion: textExpansion, overrides: overrides.withLock { $0 })
    }

    /// A feature context over these fakes, for testing a source or provider without a harness.
    public func context(featureID: String, environment: RunEnvironment = .selftest) -> FeatureContext {
        FeatureContext(featureID: featureID, environment: environment, services: services)
    }

    /// Returns once every consumer of the fakes' streams (copies, permission and settings changes,
    /// text expansion status, file changes) has handled everything it received, so a feature's
    /// background loops are done. A consumer has handled a value when it asks for the next one.
    /// A stream a feature makes and never reads holds this until the test's time limit.
    public func settle() async {
        while true {
            await pasteboard.settle()
            await permissions.settle()
            await settings.settle()
            await textExpansion.settle()
            await fileWatcher.settle()
            // Handling one stream's value may have sent to another; stop only when all are quiet.
            if pasteboard.isSettled && permissions.isSettled && settings.isSettled && textExpansion.isSettled
                && fileWatcher.isSettled
            {
                return
            }
        }
    }
}
