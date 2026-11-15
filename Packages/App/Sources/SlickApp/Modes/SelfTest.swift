import AppKit
import CoreBridge
import Foundation
import Host
import Kit
import KitHosting
import Root

/// `--selftest`: proves that the app starts, that the Rust core it links matches the header it was
/// compiled against, that it runs inside the right bundle, and that the whole composition works:
/// every feature registers and activates in the selftest environment, root search opens an
/// in-memory engine, and queries through the real ``RootSource`` find every command and a sample
/// of every catalog source. It prints one verdict line, "selftest PASS ..." or "selftest FAIL ...",
/// for `make selftest` and CI. It shows no window and takes no focus.
enum SelfTest {
    /// The outcome of one selftest run.
    struct Report {
        /// What went wrong. Empty when the selftest passed.
        var failures: [String] = []
        /// Counts that go on the verdict line, such as `features=1`.
        var facts: [String] = []
        /// The verdict line to print.
        var line = ""

        var passed: Bool { failures.isEmpty }
    }

    /// Validator findings the selftest accepts, by feature ID, each with the reason it is accepted.
    /// Every entry is a known disagreement between a feature and Kit, listed in the app report.
    static let knownIssues: [String: Set<String>] = [:]

    /// Checks the Rust core and the bundle. `bundleIdentifier` is nil when the executable runs
    /// outside an app bundle, as it does under `swift run` and in tests.
    static func check(bundleIdentifier: String?) -> Report {
        var report = Report()

        let abi = RustCore.abiVersion
        var noop = "skipped"
        if abi == RustCore.expectedABIVersion {
            do {
                try RustCore.noop()
                noop = "ok"
            } catch {
                noop = "failed"
                report.failures.append("slick_noop returned \(error)")
            }
        } else {
            // Calling into a library with another ABI is not safe, so stop here.
            report.failures.append("Rust core ABI \(abi), header expects \(RustCore.expectedABIVersion); run make core")
        }
        if let bundleIdentifier, bundleIdentifier != Brand.bundleID {
            report.failures.append("bundle identifier \(bundleIdentifier), expected \(Brand.bundleID)")
        }
        report.facts = ["abi=\(abi)", "noop=\(noop)", "bundle=\(bundleIdentifier ?? "none")"]
        finish(&report)
        return report
    }

    /// Builds the whole launcher in the selftest environment over `dataRoot`, checks it and shuts
    /// it down. Shows nothing.
    static func checkComposition(dataRoot: URL) async -> Report {
        var report = Report()
        let assembly = Assembly(
            .init(environment: .selftest, dataRoot: dataRoot, rootStorage: .inMemory, showsWindows: false))
        await assembly.start(prewarm: false)
        let runtime = assembly.runtime
        let root = assembly.root

        let ready = await within(.seconds(20)) { await root.ready() }
        if !ready { report.failures.append("root search was not ready within 20 s") }
        if root.status != .ready(persistent: false) {
            report.failures.append("root search status \(root.status), expected an in-memory engine")
        }

        // Registration and activation.
        let registered = runtime.features
        if registered.count != assembly.configuration.registrations.count {
            report.failures.append(
                "\(registered.count) of \(assembly.configuration.registrations.count) features registered")
        }
        for entry in registered where entry.isEnabled && !runtime.isActive(entry.id) {
            report.failures.append("feature \(entry.id) is on but not active")
        }
        // Features that are off until the user turns them on are checked too: switch them on in
        // this run's own folder.
        let optional = registered.filter { !$0.manifest.isEnabledByDefault }.map(\.id)
        for featureID in optional {
            await runtime.preferences.setEnabled(true, feature: featureID)
            if !runtime.isActive(featureID) { report.failures.append("feature \(featureID) did not turn on") }
        }
        if !optional.isEmpty {
            // Let the switch reach root search and let it load what the features bring.
            for _ in 0..<10 { await Task.yield() }
            await root.settle()
        }
        var known = 0
        for (featureID, found) in runtime.issues.sorted(by: { $0.key < $1.key }) {
            for issue in found {
                if knownIssues[featureID]?.contains(issue.description) == true {
                    known += 1
                } else {
                    report.failures.append("feature \(featureID): \(issue.description)")
                }
            }
        }

        // Queries through the real root search: every command by title, and up to three rows of
        // every catalog source by title.
        var expected: [(query: String, id: ItemID)] = []
        for entry in runtime.enabledFeatures {
            for command in entry.commands where command.isEnabled && command.command.showsInRoot {
                expected.append((command.command.title, command.id))
            }
            for source in entry.catalogSources {
                let rows = (try? await source.rows()) ?? []
                for row in rows.prefix(3) { expected.append((row.title, row.id)) }
            }
        }
        var found = 0
        for (query, id) in expected {
            let snapshot = root.update(query: query)
            if snapshot.rows.prefix(5).contains(where: { $0.id == id }) {
                found += 1
            } else {
                let shown = snapshot.rows.prefix(5).map(\.title)
                report.failures.append("query \"\(query)\" did not find \(id) in its first 5 rows: \(shown)")
            }
        }
        let empty = root.begin()
        root.end()
        if expected.isEmpty { report.failures.append("no command or catalog row to query") }

        // The launcher hotkey is bound to the inert hotkey system, which holds no macOS shortcut,
        // so even Command-Space binds without waiting.
        let wanted = assembly.general[HostSettings.launcherHotkey]
        if assembly.hotkey.bound != wanted || assembly.hotkey.wait != nil {
            report.failures.append("launcher hotkey bound to \(String(describing: assembly.hotkey.bound))")
        }
        _ = assembly.settings.settingsController

        await assembly.shutdown()
        report.facts = [
            "features=\(registered.count)", "optional=\(optional.count)",
            "commands=\(registered.reduce(0) { $0 + $1.commands.count })",
            "queries=\(found)/\(expected.count)", "suggested=\(empty.rows.count)", "known-issues=\(known)",
        ]
        return report
    }

    /// Starts the app without a window, runs every check, prints the verdict line with the time
    /// the whole run took, and returns the exit status.
    static func run(folders: RunFolders) async -> Int32 {
        let clock = ContinuousClock()
        let start = clock.now
        var report = check(bundleIdentifier: Bundle.main.bundleIdentifier)
        if report.passed {
            do {
                try folders.create()
                let composition = await checkComposition(dataRoot: folders.dataRoot)
                report.failures += composition.failures
                report.facts += composition.facts
            } catch {
                report.failures.append("cannot make the data folder: \(error.localizedDescription)")
            }
            folders.removeIfTemporary()
        }
        finish(&report)
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
        print(report.line + " ms=" + String(format: "%.1f", milliseconds))
        return report.passed ? 0 : 1
    }

    private static func finish(_ report: inout Report) {
        let verdict = report.passed ? "PASS" : "FAIL"
        report.line = "selftest \(verdict) " + report.facts.joined(separator: " ")
        if !report.passed {
            report.line += " failures=\"\(report.failures.joined(separator: "; "))\""
        }
    }

    /// Runs `body`, giving up after `limit`. True when it finished in time. A body that never
    /// finishes is left running, so the wait itself always ends.
    static func within(_ limit: Duration, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { @MainActor in
                await body()
                once.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume(false)
            }
        }
    }

    /// Resumes a continuation the first time only.
    private final class Once {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
