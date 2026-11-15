import Foundation
import Kit
import KitHosting
import LocalAuthentication
import Testing

@testable import Platform

@Suite(.timeLimit(.minutes(1))) struct SettingsTests {
    static let everyKind: [String: SettingStorage] = [
        "sample.flag": .bool(true),
        "sample.off": .bool(false),
        "sample.count": .int(42),
        "sample.zero": .int(0),
        "sample.one": .int(1),
        "sample.ratio": .double(0.25),
        "sample.whole": .double(3),
        "sample.name": .string("value"),
        "sample.list": .strings(["a", "b"]),
        "sample.none": .strings([]),
        "sample.blob": .data(Data([0, 1, 2])),
        "sample.cleared": .empty,
    ]

    @Test func everyKindSurvivesThePropertyListForm() {
        for (name, storage) in Self.everyKind {
            let decoded = SettingPropertyList.decode(SettingPropertyList.encode(storage))
            #expect(decoded == storage, "\(name)")
        }
        #expect(SettingPropertyList.decode(["other": 1]) == nil)
        #expect(SettingPropertyList.decode([1, 2]) == nil)
        #expect(SettingPropertyList.decode(Date()) == nil)
    }

    @Test func readsComeFromMemoryAndWritesReachTheBackendInOrder() {
        let backend = MemorySettingsBackend(["sample.loaded": .int(7)])
        let settings = PlatformSettings(backend: backend)
        #expect(settings.storage(for: "sample.loaded") == .int(7))
        #expect(settings.storage(for: "sample.missing") == nil)

        for value in 1...50 {
            settings.set(.int(value), for: "sample.count")
        }
        #expect(settings.storage(for: "sample.count") == .int(50))
        settings.set(nil, for: "sample.loaded")
        #expect(settings.storage(for: "sample.loaded") == nil)
        settings.flush()
        #expect(backend.stored["sample.count"] == .int(50))
        #expect(backend.stored["sample.loaded"] == nil)
    }

    @Test func changeStreamsHearOnlyTheirKeysAndOnlyRealChanges() async {
        let settings = PlatformSettings(backend: MemorySettingsBackend())
        var watched = settings.changes(for: ["sample.a", "sample.b"]).makeAsyncIterator()
        settings.set(.int(1), for: "sample.other")
        settings.set(.int(1), for: "sample.a")
        settings.set(.int(1), for: "sample.a")  // unchanged: no event
        settings.set(.string("x"), for: "sample.b")
        settings.set(nil, for: "sample.a")
        #expect(await watched.next() == "sample.a")
        #expect(await watched.next() == "sample.b")
        #expect(await watched.next() == "sample.a")
    }

    @Test func aStreamStopsListeningWhenItsTaskIsCancelled() async {
        let settings = PlatformSettings(backend: MemorySettingsBackend())
        let stream = settings.changes(for: ["sample.a"])
        #expect(settings.listenerCount == 1)
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value
        #expect(settings.listenerCount == 0)
    }

    @Test func typedKeysWorkThroughFeatureSettings() {
        let settings = PlatformSettings(backend: MemorySettingsBackend())
        let general = HostSettings.settings(settings)
        #expect(general[HostSettings.launcherHotkey] == KeyCombo(.space, .command))
        general[HostSettings.launcherHotkey] = nil
        #expect(settings.storage(for: "app.general.launcherHotkey") == .empty)
        #expect(general[HostSettings.launcherHotkey] == nil)
        general[HostSettings.panelSizing] = .fitContent
        #expect(general[HostSettings.panelSizing] == .fitContent)
    }

    /// The only test that writes a `UserDefaults` domain: a throwaway suite, removed at the end.
    @Test func aThrowawayDefaultsSuiteRoundTripsEveryKind() {
        let suite = "test.platform.settings.\(UUID().uuidString)"
        let backend = UserDefaultsSettingsBackend(suiteName: suite)
        defer { backend.removeDomain() }
        #expect(backend.domainName == suite)

        let settings = PlatformSettings(backend: backend)
        for (name, storage) in Self.everyKind {
            settings.set(storage, for: name)
        }
        settings.set(.int(5), for: "sample.removed")
        settings.set(nil, for: "sample.removed")
        settings.flush()

        let reloaded = PlatformSettings(backend: UserDefaultsSettingsBackend(suiteName: suite))
        for (name, storage) in Self.everyKind {
            #expect(reloaded.storage(for: name) == storage, "\(name)")
        }
        #expect(reloaded.storage(for: "sample.removed") == nil)

        backend.removeDomain()
        #expect(backend.loadAll().isEmpty)
    }
}

@Suite struct StorageTests {
    @Test func pathsFollowTheLayoutAndTouchNothing() {
        let root = FileManager.default.temporaryDirectory.appending(path: "platform-storage-\(UUID().uuidString)")
        let storage = PlatformStorage(dataRoot: root, environment: .selftest)
        let features = FeatureStorage(featureID: "clipboard", service: storage)
        #expect(features.dataDirectory == root.appending(path: "Features/clipboard/"))
        #expect(features.cacheDirectory == root.appending(path: "Caches/clipboard/"))
        #expect(features.dataFile("history.sqlite").lastPathComponent == "history.sqlite")
        #expect(storage.homeDirectory == root.appending(path: "Home/"))
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test func theHomeIsSyntheticOutsideLive() {
        let root = URL(filePath: "/synthetic/data", directoryHint: .isDirectory)
        for environment in RunEnvironment.allCases {
            let home = PlatformStorage(dataRoot: root, environment: environment).homeDirectory
            let isUnderRoot = home.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false))
            #expect(isUnderRoot == !environment.touchesRealSystem, "\(environment)")
        }
    }

    @Test func unsafeFeatureIDsStayInsideTheirFolder() {
        let root = URL(filePath: "/synthetic/data", directoryHint: .isDirectory)
        let storage = PlatformStorage(dataRoot: root, homeDirectory: root)
        for id in ["../escape", "a/b", ".hidden", "", "weird id"] {
            let folder = storage.dataDirectory(for: id).standardizedFileURL
            #expect(folder.deletingLastPathComponent().path(percentEncoded: false) == "/synthetic/data/Features/")
            #expect(!folder.lastPathComponent.contains("/") && !folder.lastPathComponent.hasPrefix("."))
        }
        #expect(PlatformStorage.folderName(for: "calendar-2") == "calendar-2")
    }

    @Test func theDefaultDataRootHonorsAnOverride() {
        #expect(
            PlatformStorage.defaultDataRoot(override: "/synthetic/override").path(percentEncoded: false)
                == "/synthetic/override/")
        #expect(PlatformStorage.defaultDataRoot(override: "~/x").path(percentEncoded: false).hasSuffix("/x/"))
        #expect(PlatformStorage.defaultDataRoot(override: "").lastPathComponent == Brand.dataDirectoryName)
        #expect(PlatformStorage.defaultDataRoot().lastPathComponent == Brand.dataDirectoryName)
    }
}

@Suite struct SecretsTests {
    @Test func secretsAreStoredReadAndDeleted() async throws {
        let keychain = MemoryKeychain()
        let secrets = KeychainSecrets(service: "test.platform.secrets", backend: keychain)
        let feature = FeatureSecrets(featureID: "ai", service: secrets)
        #expect(try await feature.value(for: "apiKey") == nil)
        try await feature.set("synthetic-key-1", for: "apiKey")
        try await feature.set("synthetic-key-2", for: "apiKey")
        #expect(try await feature.value(for: "apiKey") == "synthetic-key-2")
        #expect(try await secrets.secret(for: "ai.apiKey") == "synthetic-key-2")
        #expect(keychain.count == 1)
        try await feature.set(nil, for: "apiKey")
        try await feature.set(nil, for: "apiKey")
        #expect(try await feature.value(for: "apiKey") == nil)
        #expect(keychain.count == 0)
    }

    @Test func aSecretThatIsNotTextThrows() async throws {
        let keychain = MemoryKeychain()
        try keychain.write(Data([0xFF, 0xFE]), service: "test.platform.secrets", account: "ai.apiKey")
        let secrets = KeychainSecrets(service: "test.platform.secrets", backend: keychain)
        await #expect(throws: KeychainError.notText) { try await secrets.secret(for: "ai.apiKey") }
        #expect(KeychainSecrets.defaultService == Brand.bundleID + ".secrets")
    }

    /// Checks the Keychain queries without calling the Keychain.
    @Test func keychainQueriesNameOneGenericPasswordAndForbidUI() throws {
        let protected = SecItemKeychain.itemQuery(service: "s", account: "a", dataProtection: true)
        #expect(protected[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(protected[kSecAttrService as String] as? String == "s")
        #expect(protected[kSecAttrAccount as String] as? String == "a")
        #expect(protected[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let context = try #require(protected[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)

        let legacy = SecItemKeychain.itemQuery(service: "s", account: "a", dataProtection: false)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecUseAuthenticationContext as String] == nil)

        let item = SecItemKeychain.newItem(query: legacy, data: Data("x".utf8), account: "a", dataProtection: false)
        #expect(item[kSecValueData as String] as? Data == Data("x".utf8))
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecAttrAccessible as String] == nil)
        let protectedItem = SecItemKeychain.newItem(
            query: protected, data: Data("x".utf8), account: "a", dataProtection: true)
        #expect(
            protectedItem[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(SecItemKeychain(preferDataProtectionKeychain: false).isUsingDataProtectionKeychain == false)
    }
}

@Suite struct ClockTests {
    @Test func theLiveClockTellsTimeAndSleepsUntilCancelled() async {
        let clock = LiveClock()
        #expect(abs(clock.now.timeIntervalSinceNow) < 1)
        #expect(clock.calendar.identifier == .gregorian)
        #expect(clock.calendar.timeZone == clock.timeZone)
        let sleeper = Task { try await clock.sleep(for: .seconds(30)) }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }
}
