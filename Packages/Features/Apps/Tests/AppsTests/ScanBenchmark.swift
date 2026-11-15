import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

/// Times the scan of the real app folders and the real Settings extensions, and the main-thread
/// cost of building a row's actions. Opt in with `APPS_BENCHMARK=1`, in a release build:
///
///     APPS_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Apps test -c release \
///         -Xswiftc -enable-testing --filter ScanBenchmark
///
/// It prints counts and milliseconds only, never a name or a path. The user's own Applications
/// folder is left out: the home folder it is given does not exist. The tests run one at a time, so
/// they do not slow each other down.
@Suite(
    "Benchmark: scanning the real folders", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["APPS_BENCHMARK"] == "1"))
@MainActor
struct ScanBenchmark {
    private let home = FileManager.default.temporaryDirectory.appending(path: "apps-benchmark-no-home")

    @Test func scanApplications() async {
        let library = FolderAppLibrary.system(home: home, languages: Locale.preferredLanguages)
        let roots = library.roots(adding: [])
        let first = await Self.time { _ = await library.applications(in: roots) }
        var count = 0
        var samples: [Double] = []
        for _ in 0..<200 {
            samples.append(await Self.time { count = await library.applications(in: roots).count })
        }
        Self.report("app scan, wall", samples, extra: "apps=\(count) first=\(Self.ms(first))")
    }

    /// Splits the scan into its three parts: walking the folders, reading each Info.plist, and
    /// reading each localized table.
    @Test func scanParts() async {
        let library = FolderAppLibrary.system(home: home, languages: Locale.preferredLanguages)
        let paths = await library.applications(in: library.roots(adding: [])).map(\.path)
        let reader = library.reader
        var walk: [Double] = []
        var info: [Double] = []
        var localized: [Double] = []
        for _ in 0..<50 {
            walk.append(
                await Self.time {
                    for root in library.standardRoots { _ = DirectoryEntries(root.folder.path).map(\.name) }
                })
            info.append(await Self.time { for path in paths { _ = reader.infoDictionary(ofBundleAt: path) } })
            localized.append(
                await Self.time {
                    for path in paths {
                        _ = reader.localizedTable("InfoPlist", inBundleAt: path, developmentRegion: "en")
                    }
                })
        }
        Self.report("top-level folder listing", walk, extra: "roots=\(library.standardRoots.count)")
        Self.report("Info.plist reads", info, extra: "apps=\(paths.count)")
        Self.report("localized InfoPlist tables", localized, extra: "apps=\(paths.count)")
    }

    @Test func scanSettingsPanes() async {
        let library = FolderAppLibrary.system(home: home, languages: Locale.preferredLanguages)
        let first = await Self.time { _ = await library.settingsPanes() }
        var panes: [SystemSettingsPane] = []
        var samples: [Double] = []
        for _ in 0..<50 {
            samples.append(await Self.time { panes = await library.settingsPanes() })
        }
        let anchors = panes.reduce(0) { $0 + $1.anchors.count }
        Self.report(
            "pane scan, wall", samples, extra: "panes=\(panes.count) anchors=\(anchors) first=\(Self.ms(first))")
    }

    /// `actions(for:)` runs on the main thread when the selection settles and when the action panel
    /// opens, so it is measured as main-thread CPU time, over every real app, half of them running.
    @Test func buildActionsOnTheMainThread() async throws {
        let library = FolderAppLibrary.system(home: home, languages: Locale.preferredLanguages)
        let installed = await library.applications(in: library.roots(adding: []))
        let running = installed.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { index, app in
            RunningApp(pid: Int32(index), bundleID: app.bundleID, name: "", path: app.path, isHidden: false)
        }
        let fakes = FakeServices()
        fakes.override(AppLibraryKey.self, with: library)
        fakes.override(RunningAppsKey.self, with: SimulatedRunningApps(running))
        let harness = FeatureHarness(AppsFeature.self, fakes: fakes)
        await harness.activate()
        let rows = try await harness.catalogRows().filter { $0.id.namespace == AppCatalog.namespace }
        var samples: [Double] = []
        for _ in 0..<5 {
            for row in rows {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let actions = harness.feature.actions(forAppRow: row)
                samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
                #expect(!actions.isEmpty)
            }
        }
        Self.report("actions(for:), main-thread CPU", samples, extra: "rows=\(rows.count)")
        var build: [Double] = []
        for _ in 0..<50 {
            build.append(await Self.time { _ = await AppRows.catalog(installed, running: running, hidden: []) })
        }
        Self.report("catalog rows, wall, off main", build, extra: "rows=\(rows.count)")
    }

    private static func time(_ body: () async -> Void) async -> Double {
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await body() }
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.3f ms", value)
    }

    private static func report(_ name: String, _ samples: [Double], extra: String) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
        print("BENCH \(name): n=\(sorted.count) p50=\(ms(p50)) p99=\(ms(p99)) max=\(ms(sorted.last ?? 0)) \(extra)")
    }
}
