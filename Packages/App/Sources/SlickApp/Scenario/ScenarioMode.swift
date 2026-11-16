import AppKit
import Foundation
import Host
import Kit
import KitHosting
import LauncherUI
import Platform
import Root
import SettingsUI

/// `--scenario <file>`: Host's scenario runner on the real panel, over the real root search and
/// the real features, in the scenario environment. Services are inert, the workspace records what
/// features ask of it, apps come from the Apps feature's synthetic tree, and data lives in a
/// temporary folder.
///
/// The file is Host's format, documented in docs/SCENARIOS.md, plus ``AppStep``s for what only
/// the app can see. The app splits the steps at each app step, runs each stretch of Host's steps
/// with the time left, runs the app step, and writes one `result.json` in Host's format.
///
/// The run's clock is a ``ScenarioClock`` in UTC that `setTime` steps move. A file with
/// `"systemApps": true` lists Apple's own apps from `/System/Applications` with their real icons
/// in place of the Apps feature's made-up ones: see ``SystemApps``.
enum ScenarioMode {
    /// The most seconds the process may take: the longest scenario plus starting and stopping.
    static let processLimit: Double = 180

    /// One step of the file.
    enum Item: Equatable {
        case host(ScenarioStep)
        case app(AppStep)

        var name: String {
            switch self {
            case .host(let step): step.name
            case .app: "app"
            }
        }
    }

    /// A scenario file with app steps.
    struct File: Equatable {
        var name: String
        var timeLimit: Double
        var items: [Item]
        /// True lists the system's own apps with their real icons. See ``SystemApps``.
        var systemApps = false
        /// The run's time when it starts. Nil starts at the real time.
        var startTime: Date?
        /// True runs the first step as soon as the features are activated, before root search and
        /// the features finished loading, as a person who types at once after launch does.
        var startsBeforeReady = false
    }

    /// One step's outcome in `result.json`.
    struct StepRecord: Encodable, Equatable {
        var index: Int
        var step: String
        var passed: Bool
        var milliseconds: Double
        var note: String?
    }

    /// The run's outcome, written as `result.json` with Host's keys.
    struct ResultRecord: Encodable, Equatable {
        var name: String
        var passed: Bool
        var reason: String?
        var seconds: Double
        var captures: [String]
        var steps: [StepRecord]
    }

    enum LoadError: Error, CustomStringConvertible {
        case notAnObject
        case missing(String)
        case unknownKey(String)
        case badValue(String, String)
        case badStep(Int, String)

        var description: String {
            switch self {
            case .notAnObject: "the file is not a JSON object"
            case .missing(let key): "the file has no \"\(key)\""
            case .unknownKey(let key): "the file has an unknown key \"\(key)\""
            case .badValue(let key, let value): "cannot read \"\(value)\" as \(key)"
            case .badStep(let index, let reason): "step \(index): \(reason)"
            }
        }
    }

    /// Reads a scenario file with app steps.
    static func load(_ data: Data) throws -> File {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.notAnObject
        }
        if let unknown = object.keys.sorted().first(where: { !fileKeys.contains($0) }) {
            throw LoadError.unknownKey(unknown)
        }
        guard let name = object["name"] as? String else { throw LoadError.missing("name") }
        guard let steps = object["steps"] as? [Any] else { throw LoadError.missing("steps") }
        let limit = min((object["timeLimit"] as? NSNumber)?.doubleValue ?? 30, Scenario.maximumTimeLimit)
        var items: [Item] = []
        let decoder = JSONDecoder()
        for (offset, step) in steps.enumerated() {
            do {
                let stepData = try JSONSerialization.data(withJSONObject: step)
                if let dictionary = step as? [String: Any], dictionary.count == 1, let app = dictionary["app"] {
                    let appData = try JSONSerialization.data(withJSONObject: app)
                    items.append(.app(try decoder.decode(AppStep.self, from: appData)))
                } else {
                    items.append(.host(try decoder.decode(ScenarioStep.self, from: stepData)))
                }
            } catch {
                throw LoadError.badStep(offset + 1, String(describing: error))
            }
        }
        let systemApps = (object["systemApps"] as? Bool) ?? false
        var startTime: Date?
        if let text = object["startTime"] as? String {
            guard let date = try? Date.ISO8601FormatStyle().parse(text) else {
                throw LoadError.badValue("startTime", text)
            }
            startTime = date
        }
        let startsBeforeReady = (object["startsBeforeReady"] as? Bool) ?? false
        return File(
            name: name, timeLimit: limit, items: items, systemApps: systemApps, startTime: startTime,
            startsBeforeReady: startsBeforeReady)
    }

    /// The keys a scenario file may have. `media` holds what scenarios/media/publish.py reads.
    static let fileKeys: Set<String> = [
        "name", "timeLimit", "steps", "systemApps", "startTime", "startsBeforeReady", "media",
    ]

    /// How a scenario run is built: the scenario environment, a workspace that records, a clock
    /// the file can move and, for `systemApps`, the system's own apps and icons. Prepares the data
    /// folder for them. `surface` places the panel; tests put it off screen.
    static func configuration(
        for file: File, dataRoot: URL, surface: LauncherSurface? = nil
    ) throws -> Assembly.Configuration {
        var configuration = Assembly.Configuration(
            environment: .scenario, dataRoot: dataRoot, workspace: { RecordingWorkspace(wrapping: $0) },
            surface: surface)
        configuration.clock = ScenarioClock(startingAt: file.startTime)
        if file.systemApps {
            try SystemApps.prepare(dataRoot: dataRoot)
            configuration.icons = { SystemApps.icons(platform: $0) }
        }
        return configuration
    }

    // MARK: Running

    static func run(file url: URL, output: URL?, folders: RunFolders) async -> Int32 {
        let stem = url.deletingPathExtension().lastPathComponent
        let output =
            output
            ?? FileManager.default.temporaryDirectory.appending(path: "\(Brand.dataDirectoryName)-scenario-\(stem)")
        let file: File
        do {
            file = try load(Data(contentsOf: url))
        } catch {
            let reason = "cannot read \(url.lastPathComponent): \(error)"
            write(
                ResultRecord(name: stem, passed: false, reason: reason, seconds: 0, captures: [], steps: []), to: output
            )
            print("scenario FAIL: \(reason)")
            return 1
        }
        let configuration: Assembly.Configuration
        do {
            try folders.create()
            configuration = try self.configuration(for: file, dataRoot: folders.dataRoot)
        } catch {
            print("scenario FAIL: cannot make the data folder: \(error.localizedDescription)")
            return 1
        }
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: true)
        let result: ResultRecord
        let ready = file.startsBeforeReady ? true : await SelfTest.within(.seconds(30), { await assembly.ready() })
        if ready, let panel = assembly.panel {
            let runner = ScenarioRunner(panel: panel, output: output)
            runner.makeBackdrop = { frame in ScenarioBackdrop(frame: frame) }
            runner.log = { _ in }
            result = await run(file, runner: runner, assembly: assembly)
        } else {
            result = ResultRecord(
                name: file.name, passed: false, reason: "root search was not ready within 30 s", seconds: 0,
                captures: [], steps: [])
        }
        write(result, to: output)
        assembly.settings.existingController?.close()
        await assembly.shutdown()
        folders.removeIfTemporary()
        print("output \(output.path)")
        print(result.passed ? "scenario PASS" : "scenario FAIL: \(result.reason ?? "unknown")")
        return result.passed ? 0 : 1
    }

    /// Runs the steps in order: each stretch of Host steps through the runner, each app step here.
    /// `settingsOrigin` is where `openSettings` puts the settings window's bottom-left corner; nil
    /// puts it in the bottom-left corner of the main screen, inside the area clips record.
    static func run(
        _ file: File, runner: ScenarioRunner, assembly: Assembly, settingsOrigin: CGPoint? = nil,
        log: (String) -> Void = { print($0) }
    ) async -> ResultRecord {
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(Int(file.timeLimit * 1000))
        log("scenario \(file.name): \(file.items.count) steps, \(file.timeLimit) s at most")
        lastHotkeyRefused = nil
        var records: [StepRecord] = []
        var captures: [String] = []
        var reason: String?
        var index = 0
        while index < file.items.count, reason == nil {
            guard seconds(deadline - ContinuousClock.now) > 0 else {
                reason = "time limit of \(file.timeLimit) s reached before step \(index + 1)"
                break
            }
            if case .app(let step) = file.items[index] {
                let stepStart = ContinuousClock.now
                var made: [String] = []
                let problem = await perform(
                    step, assembly: assembly, runner: runner, settingsOrigin: settingsOrigin, captures: &made)
                captures += made
                let record = StepRecord(
                    index: index + 1, step: "app", passed: problem == nil,
                    milliseconds: seconds(ContinuousClock.now - stepStart) * 1000, note: problem)
                records.append(record)
                log("step \(index + 1) app: \(problem ?? "ok")")
                if let problem { reason = "step \(index + 1) app: \(problem)" }
                index += 1
                continue
            }
            var steps: [ScenarioStep] = []
            let first = index
            while index < file.items.count, case .host(let step) = file.items[index] {
                steps.append(step)
                index += 1
            }
            let left = seconds(deadline - ContinuousClock.now)
            let stretch = await runner.run(Scenario(name: file.name, timeLimit: max(left, 0.1), steps: steps))
            captures += stretch.captures
            for step in stretch.steps {
                let number = first + step.index
                records.append(
                    StepRecord(
                        index: number, step: step.step, passed: step.passed, milliseconds: step.milliseconds,
                        note: step.note))
                log("step \(number) \(step.step): \(step.note ?? "ok")")
                if !step.passed, reason == nil { reason = "step \(number) \(step.step): \(step.note ?? "failed")" }
            }
            if !stretch.passed, reason == nil {
                reason = stretch.reason ?? "step \(first + stretch.steps.count + 1) did not run"
            }
        }
        return ResultRecord(
            name: file.name, passed: reason == nil, reason: reason, seconds: seconds(ContinuousClock.now - started),
            captures: captures, steps: records)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: App steps

    /// Does an app step's actions, then checks it. Nil when everything held. Captures it writes
    /// are added to `captures`.
    static func perform(
        _ step: AppStep, assembly: Assembly, runner: ScenarioRunner? = nil, settingsOrigin: CGPoint? = nil,
        captures: inout [String]
    ) async -> String? {
        var problems: [String] = []
        problems += await playContext(step, assembly: assembly)
        if step.pressHotkey == true, !assembly.hotkey.simulatePress() {
            problems.append("no launcher hotkey is bound")
        }
        if let shortcuts = step.systemShortcuts {
            problems += playSystemShortcuts(shortcuts, hotkeys: assembly.platform.hotkeys)
        }
        for (featureID, enabled) in (step.setFeatures ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard assembly.runtime.feature(featureID) != nil else {
                problems.append("no feature \(featureID)")
                continue
            }
            await assembly.runtime.preferences.setEnabled(enabled, feature: featureID)
        }
        for (key, value) in (step.setSettings ?? [:]).sorted(by: { $0.key < $1.key }) {
            if key.contains(".") {
                // A feature's setting by its stored name, such as `windows.showsLayoutName`.
                assembly.services.settings.set(storage(value), for: key)
            } else if let problem = set(key, to: value, in: assembly.general) {
                problems.append(problem)
            }
        }
        if let request = step.setHotkey {
            problems += setHotkey(request, preferences: assembly.runtime.preferences)
        }
        if let request = step.setFallbacks {
            problems += setFallbacks(request, assembly: assembly)
        }
        if let request = step.onboarding {
            problems += await OnboardingRehearsal.chooseOptionalFeatures(
                request.features, dependencies: assembly.dependencies)
        }
        for text in step.copyAsOtherApp ?? [] {
            await assembly.platform.copyAsAnotherApp(text)
            if let problem = await waitForHistory(text, assembly: assembly) { problems.append(problem) }
        }
        if let keys = step.pressKeys {
            if let problem = press(keys, hotkeys: assembly.platform.hotkeys) { problems.append(problem) }
            // Let the run the hotkey starts reach its handler.
            for _ in 0..<5 { await Task.yield() }
        }
        if step.setFeatures != nil || step.setSettings != nil || step.setHotkey != nil || step.onboarding != nil
            || step.setFallbacks != nil
        {
            // Let the changes reach the runtime, root search and the panel, let a feature switched
            // on finish loading, and let root search load what it brings back.
            for _ in 0..<10 { await Task.yield() }
            if await !SelfTest.within(readyWait, { await assembly.runtime.waitUntilFeaturesAreReady() }) {
                problems.append("a feature did not finish loading within \(readyWait)")
            }
            await assembly.root.settle()
        }
        if step.waitUntilReady == true, await !SelfTest.within(readyWait, { await assembly.ready() }) {
            problems.append("root search and the features were not ready within \(readyWait)")
        }
        if let link = step.resolvedLink {
            if let url = URL(string: link) {
                assembly.links.handle(url)
            } else {
                problems.append("cannot read the link \(link)")
            }
            // Let the run a link starts reach its handler.
            for _ in 0..<5 { await Task.yield() }
        }
        if let title = step.waitForRow {
            if let panel = assembly.panel {
                if let problem = await waitForRow(title, panel: panel) { problems.append(problem) }
            } else {
                problems.append("waitForRow needs the panel")
            }
        }
        if let title = step.select {
            if let runner {
                if let problem = await select(title, runner: runner) { problems.append(problem) }
            } else {
                problems.append("select needs the panel")
            }
        }
        problems += await settingsWindow(
            step, assembly: assembly, runner: runner, origin: settingsOrigin, captures: &captures)
        if let expected = step.linkOutcome {
            let last = assembly.links.outcomes.last.map(outcomeName) ?? "none"
            if last != expected { problems.append("the last link was \(last), expected \(expected)") }
        }
        if let expected = step.launched {
            let launched = assembly.recordingWorkspace?.launchedBundleIDs ?? []
            if launched != expected { problems.append("launched \(launched), expected \(expected)") }
        }
        if let expected = step.opened {
            let opened = (assembly.recordingWorkspace?.openedURLs ?? []).map(\.absoluteString)
            if opened != expected { problems.append("opened \(opened), expected \(expected)") }
        }
        if let expected = step.settings {
            let requests = assembly.settings.requests.map(settingsName)
            if requests != expected { problems.append("settings opened \(requests), expected \(expected)") }
        }
        if let expected = step.aliases {
            let aliases = assembly.runtime.preferences.aliases
            for (raw, alias) in expected.sorted(by: { $0.key < $1.key }) {
                let actual = ItemID(rawValue: raw).flatMap { aliases[$0] }
                if actual != alias { problems.append("alias of \(raw) was \(actual ?? "none"), expected \(alias)") }
            }
        }
        if let expected = step.favorites {
            let favorites = assembly.runtime.preferences.favorites.map(\.rawValue)
            if favorites != expected { problems.append("favorites were \(favorites), expected \(expected)") }
        }
        if let expected = step.resolvedHUD {
            let last = assembly.recordingHUD?.shown.last?.title
            if last != expected { problems.append("the last HUD was \(last ?? "none"), expected \(expected)") }
        }
        if let expected = step.pasteboardText {
            let text = await assembly.services.pasteboard.recentText(offset: 0)
            if text != expected { problems.append("the pasteboard held \(text ?? "nothing"), expected \(expected)") }
        }
        if let expected = step.hotkeyBound, (assembly.hotkey.bound != nil) != expected {
            problems.append(expected ? "no launcher hotkey is bound" : "a launcher hotkey is bound")
        }
        if let expected = step.hotkeyWaiting {
            let owner = assembly.hotkey.wait?.owner ?? ""
            if owner != expected { problems.append("the launcher hotkey waited for \(owner), expected \(expected)") }
        }
        if let expected = step.launcherHotkey {
            let bound = assembly.hotkey.bound?.description ?? ""
            if bound != expected { problems.append("the launcher hotkey was \(bound), expected \(expected)") }
        }
        if let expected = step.hotkeyRefused, lastHotkeyRefused != expected {
            problems.append(expected ? "the hotkey was not refused" : "the hotkey was refused")
        }
        for (raw, keys) in (step.itemHotkeys ?? [:]).sorted(by: { $0.key < $1.key }) {
            let actual = ItemID(rawValue: raw).flatMap { assembly.runtime.preferences.hotkeys[$0] }?.description ?? ""
            if actual != keys { problems.append("hotkey of \(raw) was \(actual), expected \(keys)") }
        }
        if let expected = step.theme {
            problems += checkTheme(expected, assembly: assembly)
        }
        for (featureID, active) in (step.featuresActive ?? [:]).sorted(by: { $0.key < $1.key })
        where assembly.runtime.isActive(featureID) != active {
            problems.append("feature \(featureID) was \(active ? "not active" : "active")")
        }
        if let expected = step.fallbacksOn {
            let on = assembly.runtime.fallbacks(assembly.runtime.preferences.fallbackChoices).filter(\.isOn)
                .map(\.id.rawValue)
            if on != expected { problems.append("the fallbacks on were \(on), expected \(expected)") }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Changes the fallback choices the way the root search pane does: the order first, through
    /// every fallback the pane lists, then each switch. Returns the problems.
    static func setFallbacks(_ request: AppStep.FallbackRequest, assembly: Assembly) -> [String] {
        let preferences = assembly.runtime.preferences
        let listed = assembly.runtime.fallbacks(preferences.fallbackChoices).map(\.id)
        var problems: [String] = []
        func known(_ raw: String) -> ItemID? {
            guard let id = ItemID(rawValue: raw), listed.contains(id) else {
                problems.append("no fallback \(raw); the pane lists \(listed.map(\.rawValue))")
                return nil
            }
            return id
        }
        if let order = request.order {
            let ids = order.compactMap(known)
            // The pane always passes every fallback it lists; the ones the file leaves out keep
            // their places after the ones it names.
            preferences.setFallbackOrder(ids + listed.filter { !ids.contains($0) })
        }
        for (raw, isOn) in (request.on ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let id = known(raw) { preferences.setFallback(id, isOn: isOn) }
        }
        return problems
    }

    /// Moves the run's clock, plays a session start and puts an app in front, in that order, then
    /// lets root search catch up. Returns the problems.
    static func playContext(_ step: AppStep, assembly: Assembly) async -> [String] {
        guard step.setTime != nil || step.advanceClock != nil || step.sessionStart != nil || step.frontApp != nil
        else { return [] }
        var problems: [String] = []
        if let date = step.setTime {
            if let clock = assembly.scenarioClock {
                if !clock.move(to: date) { problems.append("the run's time is already past \(date)") }
            } else {
                problems.append("the run has no clock a scenario can move")
            }
        }
        if let seconds = step.advanceClock {
            if let clock = assembly.scenarioClock {
                clock.move(to: clock.now.addingTimeInterval(seconds))
            } else {
                problems.append("the run has no clock a scenario can move")
            }
        }
        if step.sessionStart == true {
            assembly.platform.systemContext.sessionStarted(at: assembly.services.clock.now)
        }
        if let bundleID = step.frontApp {
            let name = assembly.root.row(for: ItemID("app", bundleID))?.title ?? appName(bundleID)
            assembly.recordingWorkspace?.setFrontmost(AppInfo(bundleID: bundleID, name: name))
            assembly.platform.systemContext.update { $0.frontmostBundleID = bundleID }
        }
        // Let the hourly tick, the session start and the context change reach root search, and let
        // it prepare the empty state again.
        for _ in 0..<10 { await Task.yield() }
        await assembly.root.settle()
        return problems
    }

    /// A name for an app root search does not know: the last part of its bundle ID, capitalized.
    static func appName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The longest an app step waits for the features' own loading.
    static let readyWait = Duration.seconds(20)

    /// The longest a copy waits to reach clipboard history.
    static let historyWait = Duration.seconds(5)

    /// Waits until clipboard history holds `text` as its newest entry, looking every 10 ms, for at
    /// most ``historyWait``. The pasteboard is polled four times a second, so a fixed pause would
    /// pass on a quiet Mac and fail on a busy one. With no clipboard history on there is nothing to
    /// wait for. Returns the problem, or nil.
    static func waitForHistory(_ text: String, assembly: Assembly) async -> String? {
        guard let reader = assembly.historyReader else { return nil }
        let deadline = ContinuousClock.now + historyWait
        while await reader.text(offset: 0) != text {
            guard ContinuousClock.now < deadline else {
                return "clipboard history did not take \"\(text)\" within \(historyWait)"
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// The longest a `waitForRow` step waits.
    static let rowWait = Duration.seconds(5)

    /// Waits until the top page shows a row or cell titled `title`, looking every 10 ms, for at
    /// most ``rowWait``. Returns the problem, or nil.
    static func waitForRow(_ title: String, panel: PanelController) async -> String? {
        let deadline = ContinuousClock.now + rowWait
        while !panel.shownTitles.contains(title) {
            guard ContinuousClock.now < deadline else {
                return "no row \"\(title)\" after \(rowWait); rows were \(panel.shownTitles)"
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Selects the row or cell titled `title` on the top page by pressing Down, then Up, through
    /// the runner, as a person would. Returns the problem, or nil.
    static func select(_ title: String, runner: ScenarioRunner) async -> String? {
        let panel = runner.panel
        guard panel.shownTitles.contains(title) else {
            return "no row \"\(title)\" to select; rows were \(panel.shownTitles)"
        }
        let limit = panel.shownTitles.count
        for key in ["down", "up"] {
            for _ in 0...limit {
                if panel.selectedTitle == title { return nil }
                let pressed = await runner.run(Scenario(name: "select", timeLimit: 5, steps: [.press(key)]))
                if !pressed.passed { return pressed.reason ?? "cannot press \(key)" }
            }
        }
        return panel.selectedTitle == title
            ? nil : "cannot select \"\(title)\"; the selection stayed on \(panel.selectedTitle ?? "nothing")"
    }

    /// Opens, captures and closes the real settings window for `openSettings`, `captureSettings`
    /// and `closeSettings`. Returns the problems.
    static func settingsWindow(
        _ step: AppStep, assembly: Assembly, runner: ScenarioRunner?, origin: CGPoint?, captures: inout [String]
    ) async -> [String] {
        var problems: [String] = []
        if let name = step.openSettings {
            if let pane = SettingsPaneID(rawValue: name) {
                let place = origin ?? defaultSettingsOrigin()
                if assembly.settings.settingsController.showForCapture(pane, at: place) == nil {
                    problems.append("the settings window could not be put at \(place)")
                }
                // Let SwiftUI lay the pane out before anything captures it.
                for _ in 0..<10 { await Task.yield() }
            } else {
                problems.append("no settings pane \(name)")
            }
        }
        if let name = step.captureSettings {
            if let frame = assembly.settings.settingsController.captureFrame, let runner {
                do {
                    let image = try await runner.capture(frame)
                    let url = runner.output.appending(path: "captures/\(name).png")
                    try PanelSnapshot.writePNG(image, to: url)
                    captures.append(url.path)
                } catch {
                    problems.append("cannot capture the settings window: \(error)")
                }
            } else {
                problems.append("no settings window to capture; open one with openSettings first")
            }
        }
        if step.closeSettings == true {
            assembly.settings.existingController?.close()
        }
        return problems
    }

    /// The bottom-left corner of the main screen, inside the area a clip records.
    static func defaultSettingsOrigin() -> CGPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return .zero }
        return CGPoint(x: visible.minX + 20, y: visible.minY + 20)
    }

    /// Makes the run's inert hotkey system report macOS shortcuts on these combinations. Returns the
    /// problems.
    static func playSystemShortcuts(_ keys: [String], hotkeys: HotkeyCenter) -> [String] {
        guard let system = hotkeys.system as? InertHotkeySystem else { return ["the hotkey system is not inert"] }
        var shortcuts: [SymbolicHotkey] = []
        var problems: [String] = []
        for text in keys {
            if let combo = KeyCombo(parsing: text) {
                shortcuts.append(SymbolicHotkey(holding: combo))
            } else {
                problems.append("cannot read the keys \(text)")
            }
        }
        system.setSymbolicHotkeys(shortcuts)
        return problems
    }

    /// Whether the last `setHotkey` of the run was refused. Nil before the first one.
    static var lastHotkeyRefused: Bool?

    /// Sets one general setting a scenario may change. Returns the problem, or nil.
    static func set(_ key: String, to value: AppStep.SettingValue, in general: FeatureSettings) -> String? {
        switch (key, value) {
        case ("themeName", .text(let name)):
            general[HostSettings.themeName] = name
        case ("visibleRows", .number(let rows)):
            general[HostSettings.visibleRows] = rows
        case ("inlineCompletion", .bool(let on)):
            general[HostSettings.inlineCompletion] = on
        case ("panelSizing", .text(let raw)):
            guard let sizing = HostSettings.PanelSizing(rawValue: raw) else { return "no panel sizing \(raw)" }
            general[HostSettings.panelSizing] = sizing
        case ("launcherHotkey", .none):
            general[HostSettings.launcherHotkey] = nil
        case ("launcherHotkey", .text(let keys)):
            guard let combo = KeyCombo(parsing: keys) else { return "cannot read the keys \(keys)" }
            general[HostSettings.launcherHotkey] = combo
        case ("tabCommand", .text(let id)):
            general[HostSettings.tabCommand] = id
        default:
            return "cannot set \(key) to \(value)"
        }
        return nil
    }

    /// Plays a press of the hotkey registered for `keys`, as Carbon would report it.
    static func press(_ keys: String, hotkeys: HotkeyCenter) -> String? {
        guard let combo = KeyCombo(parsing: keys) else { return "cannot read the keys \(keys)" }
        guard let id = hotkeys.registered.first(where: { $0.value == combo })?.key,
            let number = hotkeys.number(for: id)
        else { return "no hotkey is registered for \(keys)" }
        hotkeys.dispatch(number: number)
        return nil
    }

    /// A value from a scenario file as the settings service stores it.
    static func storage(_ value: AppStep.SettingValue) -> SettingStorage {
        switch value {
        case .bool(let value): .bool(value)
        case .number(let value): .int(value)
        case .text(let value): .string(value)
        case .none: .empty
        }
    }

    /// Sets an item hotkey the way settings does and notes whether it was refused.
    static func setHotkey(_ request: AppStep.HotkeyRequest, preferences: HostPreferences) -> [String] {
        guard let id = ItemID(rawValue: request.item) else { return ["cannot read the item \(request.item)"] }
        var combo: KeyCombo?
        if !request.keys.isEmpty {
            guard let parsed = KeyCombo(parsing: request.keys) else { return ["cannot read the keys \(request.keys)"] }
            combo = parsed
        }
        do {
            try preferences.setHotkey(combo, for: id)
            lastHotkeyRefused = false
        } catch {
            lastHotkeyRefused = true
        }
        return []
    }

    /// The selected theme is `name`, and the panel draws it.
    static func checkTheme(_ name: String, assembly: Assembly) -> [String] {
        var problems: [String] = []
        if assembly.themes.selectedName != name {
            problems.append("the theme was \(assembly.themes.selectedName), expected \(name)")
        }
        if let surface = assembly.panel?.surface {
            var expected = assembly.themes.current
            expected.list.maxVisibleRows = surface.theme.list.maxVisibleRows
            if surface.theme != expected { problems.append("the panel does not draw the theme \(name)") }
        }
        return problems
    }

    static func outcomeName(_ outcome: DeepLinkRouter.Outcome) -> String {
        switch outcome {
        case .openedLauncher: "openedLauncher"
        case .asked: "asked"
        case .ran: "ran"
        case .openedSettings: "openedSettings"
        case .openedFeatureSettings: "openedFeatureSettings"
        case .refused: "refused"
        }
    }

    static func settingsName(_ request: SettingsOpener.Request) -> String {
        switch request {
        case .pane(let pane): pane?.rawValue ?? ""
        case .feature(let id): "features/" + id
        }
    }

    private static func write(_ result: ResultRecord, to output: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try encoder.encode(result).write(to: output.appending(path: "result.json"), options: .atomic)
        } catch {
            print("cannot write result.json: \(error)")
        }
    }
}
