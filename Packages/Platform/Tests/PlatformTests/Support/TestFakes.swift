import Foundation
import Kit
import Synchronization

@testable import Platform

/// A permission system that answers from a table and records every call. It never touches macOS.
nonisolated final class FakePermissionSystem: PermissionSystem {
    struct State {
        var checks: [Permission: PermissionStatus] = [:]
        var answers: [Permission: PermissionStatus] = [:]
        var checkCount = 0
        var requests: [Permission] = []
        var openedURLs: [URL] = []
        /// Checks that take this long, the way TCC daemon checks do.
        var slowChecks: [Permission: Duration] = [:]
        var rechecks: [Permission: PermissionStatus] = [:]
        var recheckCount = 0
        var waiting: Set<Permission> = []
    }

    let state = Mutex(State())

    /// Sets what ``check(_:)`` reports. Nil means "no safe check exists".
    func setCheck(_ status: PermissionStatus?, for permission: Permission) {
        state.withLock { $0.checks[permission] = status }
    }

    /// Sets what ``request(_:)`` answers, and what checks report afterwards when `updatesCheck`.
    func setAnswer(_ status: PermissionStatus?, for permission: Permission) {
        state.withLock { $0.answers[permission] = status }
    }

    var checkCount: Int { state.withLock { $0.checkCount } }
    var recheckCount: Int { state.withLock { $0.recheckCount } }

    /// Sets what ``recheck(_:)`` finds.
    func setRecheck(_ status: PermissionStatus?, for permission: Permission) {
        state.withLock { $0.rechecks[permission] = status }
    }

    func recheck(_ permission: Permission) async -> PermissionStatus? {
        state.withLock { state in
            state.recheckCount += 1
            return state.rechecks[permission]
        }
    }
    var requests: [Permission] { state.withLock { $0.requests } }
    var openedURLs: [URL] { state.withLock { $0.openedURLs } }

    func check(_ permission: Permission) -> PermissionStatus? {
        if let delay = state.withLock({ $0.slowChecks[permission] }) {
            Thread.sleep(forTimeInterval: delay.timeInterval)
        }
        return state.withLock { state in
            state.checkCount += 1
            return state.checks[permission]
        }
    }

    /// Makes checks of the permission take `delay`, and say they may wait.
    func setSlow(_ permission: Permission, delay: Duration) {
        state.withLock { $0.slowChecks[permission] = delay }
    }

    func checkMayWait(_ permission: Permission) -> Bool {
        state.withLock { $0.slowChecks[permission] != nil }
    }

    func request(_ permission: Permission) async -> PermissionStatus? {
        state.withLock { state in
            state.requests.append(permission)
            return state.answers[permission]
        }
    }

    func open(settingsURL: URL) async {
        state.withLock { $0.openedURLs.append(settingsURL) }
    }

    /// Plays an Automation target that is not running and that a request would not start.
    func setWaiting(_ permission: Permission, _ waits: Bool) {
        state.withLock { state in
            if waits { state.waiting.insert(permission) } else { state.waiting.remove(permission) }
        }
    }

    func waitsForApp(_ permission: Permission) -> Bool {
        state.withLock { $0.waiting.contains(permission) }
    }
}

/// A workspace system that opens nothing and records what it was asked.
nonisolated final class FakeWorkspaceSystem: WorkspaceSystem {
    struct State {
        var opened: [URL] = []
        var openedWith: [(urls: [URL], application: URL)] = []
        var revealed: [URL] = []
        var trashed: [URL] = []
        var launched: [URL] = []
        var installed: [String: URL] = [:]
        var handlers: [URL] = []
        var refusesToTrash: Set<URL> = []
        var lookups: [String] = []
    }

    let state = Mutex(State())

    func open(_ url: URL) async throws {
        state.withLock { $0.opened.append(url) }
    }

    func open(_ urls: [URL], withApplicationAt application: URL) async throws {
        state.withLock { $0.openedWith.append((urls, application)) }
    }

    func reveal(_ urls: [URL]) async {
        state.withLock { $0.revealed += urls }
    }

    func moveToTrash(_ url: URL) throws -> URL {
        try state.withLock { state in
            if state.refusesToTrash.contains(url) { throw CocoaError(.fileWriteNoPermission) }
            state.trashed.append(url)
            return URL(filePath: "/synthetic-trash").appending(path: url.lastPathComponent)
        }
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        state.withLock { $0.handlers }
    }

    func applicationURL(bundleID: String) -> URL? {
        state.withLock { state in
            state.lookups.append(bundleID)
            return state.installed[bundleID]
        }
    }

    func openApplication(at url: URL) async throws {
        state.withLock { $0.launched.append(url) }
    }
}

/// A hotkey system that registers nothing with macOS and records every call.
nonisolated final class FakeHotkeySystem: HotkeySystem {
    struct Registration: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
        var number: UInt32
    }

    struct State {
        var registered: [HotkeyToken: Registration] = [:]
        var unregistered: [HotkeyToken] = []
        var symbolic: [SymbolicHotkey] = []
        /// Makes the next registration fail with this code, once.
        var failure: Int32?
        var nextToken: UInt = 1
        var pressHandler: (@MainActor @Sendable (UInt32) -> Void)?
    }

    let state = Mutex(State())

    var registrations: [Registration] { state.withLock { Array($0.registered.values) } }

    func register(keyCode: UInt32, modifiers: UInt32, number: UInt32) throws -> HotkeyToken {
        try state.withLock { state in
            if let failure = state.failure {
                state.failure = nil
                throw HotkeyError.registrationFailed(code: failure)
            }
            let token = HotkeyToken(raw: state.nextToken)
            state.nextToken += 1
            state.registered[token] = Registration(keyCode: keyCode, modifiers: modifiers, number: number)
            return token
        }
    }

    func unregister(_ token: HotkeyToken) {
        state.withLock { state in
            state.registered[token] = nil
            state.unregistered.append(token)
        }
    }

    func symbolicHotkeys() -> [SymbolicHotkey] {
        state.withLock { $0.symbolic }
    }

    func setPressHandler(_ handler: @escaping @MainActor @Sendable (UInt32) -> Void) {
        state.withLock { $0.pressHandler = handler }
    }

    /// Plays the system reporting a press, the way the Carbon handler does.
    @MainActor func press(number: UInt32) {
        state.withLock { $0.pressHandler }?(number)
    }
}

/// A fresh temporary folder, removed when the value is released.
nonisolated final class TemporaryFolder: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(
            path: "platform-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a synthetic app bundle with an Info.plist and returns its location.
    @discardableResult
    func makeApp(_ relativePath: String, info: [String: String]) throws -> URL {
        let app = url.appending(path: relativePath, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return app
    }
}
