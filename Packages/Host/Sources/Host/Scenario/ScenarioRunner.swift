import AppKit
import Foundation
import Kit
import LauncherUI

/// Runs a ``Scenario`` against a real ``PanelController``, through the entry points the keyboard
/// reaches: the search field's delegate, the focused card's or form field's editor, and the
/// overlay's own key handling. Nothing is posted to the system.
///
/// While it runs, key events from the hardware are dropped, so a person typing at the Mac cannot
/// change the result. The panel sits in the bottom-left corner of the main screen and never takes
/// key status, except for a capture that asks for the key look, which holds it for about 120 ms.
/// The whole run is bounded by the scenario's time limit. Captures and `result.json` go to the
/// output folder, and the last line printed is `scenario PASS`, or `scenario FAIL: ` and the reason.
///
/// App builds the panel over the real root search and features, in the `scenario` environment, and
/// hands it over:
///
/// ```swift
/// let runner = ScenarioRunner(panel: panel, output: folder)
/// let passed = await runner.run(file: scenarioURL)
/// ```
@MainActor public final class ScenarioRunner {
    /// One step's outcome.
    public struct StepResult: Sendable, Encodable, Equatable {
        public var index: Int
        public var step: String
        public var passed: Bool
        public var milliseconds: Double
        public var note: String?
    }

    /// The whole run's outcome, written as `result.json`.
    public struct Result: Sendable, Encodable, Equatable {
        public var name: String
        public var passed: Bool
        /// Why the run failed; nil when it passed.
        public var reason: String?
        public var steps: [StepResult]
        /// The PNG files written, as paths.
        public var captures: [String]
        public var seconds: Double
    }

    public let panel: PanelController
    public let output: URL
    /// Makes a window to show behind the panel during a capture, such as a synthetic backdrop.
    /// It is closed after the capture. Nil captures the panel alone.
    public var makeBackdrop: ((CGRect) -> NSWindow?)?
    /// Takes the picture. ScreenCaptureKit of this process's own windows by default.
    public var capture: @MainActor @Sendable (CGRect) async throws -> CGImage = { try await PanelSnapshot.capture($0) }
    /// Where progress lines go. Standard output by default.
    public var log: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }
    /// Takes clips for `record` steps. A build made with `SCENARIO_RECORDING=1` has one; other
    /// builds have none, and a `record` step fails.
    public var recorder: (any ScenarioRecorder)? = ScenarioRunner.makeRecorder()

    private var keyMonitor: Any?
    private var deadline: ContinuousClock.Instant = .now
    private var captures: [String] = []
    /// The clip being recorded. It lasts across runs, so a caller can split a file at its own
    /// steps and run the stretches in turn.
    private var recording: ScenarioRecording?
    private var previousStep: ScenarioStep?

    /// - Parameters:
    ///   - panel: The panel to drive, over whatever root search and features the caller wired.
    ///   - output: The folder for captures and `result.json`.
    ///   - placesInCorner: Moves the panel to the bottom-left corner of the main screen.
    public init(panel: PanelController, output: URL, placesInCorner: Bool = true) {
        self.panel = panel
        self.output = output
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        if placesInCorner, let visible = NSScreen.main?.visibleFrame {
            panel.surface.place(windowOrigin: CGPoint(x: visible.minX + 16, y: visible.minY + 16))
        }
    }

    // MARK: Running

    /// Reads a scenario file, runs it, writes the result and prints the verdict. True when it
    /// passed.
    public func run(file: URL) async -> Bool {
        let scenario: Scenario
        do {
            scenario = try Scenario.load(file)
        } catch {
            let reason = "cannot read \(file.lastPathComponent): \(error)"
            write(
                Result(name: file.lastPathComponent, passed: false, reason: reason, steps: [], captures: [], seconds: 0)
            )
            log("scenario FAIL: \(reason)")
            return false
        }
        var result = await run(scenario)
        if recording != nil {
            recording = nil
            await recorder?.cancel()
            if result.passed {
                result.passed = false
                result.reason = "the file ends while a clip is recording; add a stopRecording step"
            }
        }
        write(result)
        log(result.passed ? "scenario PASS" : "scenario FAIL: \(result.reason ?? "unknown")")
        return result.passed
    }

    /// Runs a scenario and returns what happened. Writes captures, not the result file.
    public func run(_ scenario: Scenario) async -> Result {
        let started = ContinuousClock.now
        deadline = started + .milliseconds(Int(scenario.timeLimit * 1000))
        captures = []
        ignoreHardwareKeys(true)
        defer { ignoreHardwareKeys(false) }
        log("scenario \(scenario.name): \(scenario.steps.count) steps, \(scenario.timeLimit) s at most")
        var results: [StepResult] = []
        var reason: String?
        for (index, step) in scenario.steps.enumerated() {
            let number = index + 1
            guard ContinuousClock.now < deadline else {
                reason = "time limit of \(scenario.timeLimit) s reached before step \(number)"
                break
            }
            let stepStart = ContinuousClock.now
            var problem: String?
            if let recording {
                await pause(ScenarioPacing.pause(before: step, after: previousStep) * recording.pace)
                problem = interruption()
            }
            if problem == nil { problem = await perform(step) }
            previousStep = step
            if recording != nil {
                recorder?.stepDidRun(step)
                if problem == nil { problem = interruption() }
                if problem != nil {
                    // A clip with a failed step or a person's input in it is never kept.
                    recording = nil
                    await recorder?.cancel()
                }
            }
            let milliseconds = Self.milliseconds(ContinuousClock.now - stepStart)
            results.append(
                StepResult(
                    index: number, step: step.name, passed: problem == nil, milliseconds: milliseconds, note: problem))
            log("step \(number) \(step.name): \(problem ?? "ok")")
            if let problem {
                reason = "step \(number) \(step.name): \(problem)"
                break
            }
        }
        if reason != nil, recording != nil {
            recording = nil
            await recorder?.cancel()
        }
        let seconds = Self.milliseconds(ContinuousClock.now - started) / 1000
        return Result(
            name: scenario.name, passed: reason == nil, reason: reason, steps: results, captures: captures,
            seconds: seconds)
    }

    /// Does one step. Returns nil when it went as asked, or what went wrong.
    func perform(_ step: ScenarioStep) async -> String? {
        switch step {
        case .summon:
            panel.summon()
            return panel.isPanelVisible ? nil : "the panel did not show"
        case .dismiss:
            panel.dismiss()
            return nil
        case .type(let text):
            for (index, character) in text.enumerated() {
                if let recording {
                    await pause(ScenarioPacing.pause(beforeCharacter: character, at: index) * recording.pace)
                    if let problem = interruption() { return problem }
                }
                type(character)
            }
            return nil
        case .press(let keys):
            guard let press = KeyPress(keys) else { return "cannot read the key combination \"\(keys)\"" }
            self.press(press)
            return nil
        case .wait(let seconds):
            await pause(seconds)
            return nil
        case .waitUntilIdle(let seconds):
            return await waitUntilIdle(seconds)
        case .expect(let expectation):
            return check(expectation)
        case .fill(let field, let value):
            return fill(field, value)
        case .capture(let name, let key):
            return await capture(name, key: key)
        case .record(let recording):
            return await startRecording(recording)
        case .stopRecording(let output):
            return await stopRecording(output)
        }
    }

    private var remainingSeconds: Double {
        max(0, Self.milliseconds(deadline - ContinuousClock.now) / 1000)
    }

    /// Sleeps up to `seconds`, within the time limit. While recording it wakes as soon as a
    /// person touches the Mac.
    private func pause(_ seconds: Double) async {
        let end = ContinuousClock.now + .milliseconds(Int(min(seconds, remainingSeconds) * 1000))
        while ContinuousClock.now < end {
            if recording != nil, recorder?.inputArrived == true { return }
            let left = end - ContinuousClock.now
            try? await Task.sleep(for: min(left, recording == nil ? left : .milliseconds(50)))
        }
    }

    // MARK: Recording

    /// The recorder this build makes for `record` steps: one with `SCENARIO_RECORDING`, none
    /// without.
    public static func makeRecorder() -> (any ScenarioRecorder)? {
        #if SCENARIO_RECORDING
            ScenarioClipRecorder()
        #else
            nil
        #endif
    }

    /// Why the run must stop now that a person touched the Mac during the clip, or nil.
    private func interruption() -> String? {
        guard recording != nil, recorder?.inputArrived == true else { return nil }
        return "input arrived during the clip, so it was thrown out"
    }

    private func startRecording(_ request: ScenarioRecording) async -> String? {
        guard let recorder else {
            return "this build cannot record; build the app with SCENARIO_RECORDING=1, see docs/SCENARIOS.md"
        }
        guard recording == nil else { return "a clip is already recording" }
        if let problem = await recorder.start(
            request, panel: panel, folder: output.appending(path: "clips", directoryHint: .isDirectory))
        {
            return problem
        }
        recording = request
        previousStep = nil
        await pause(request.lead)
        return nil
    }

    private func stopRecording(_ request: ScenarioClipOutput) async -> String? {
        guard let recorder, recording != nil else { return "no clip is recording" }
        await pause(request.tail)
        if let problem = interruption() { return problem }
        recording = nil
        switch await recorder.stop(request) {
        case .success(let files):
            captures += files
            return nil
        case .failure(let failure):
            return failure.description
        }
    }

    // MARK: Keys

    /// A key combination as a scenario names it: modifiers, then the key, joined by `+`.
    struct KeyPress: Equatable {
        var key: String
        var modifiers: KeyChord.Modifiers

        init?(_ text: String) {
            var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            // "cmd++" names the plus key.
            if parts.count >= 2, parts.suffix(2) == ["", ""] { parts = parts.dropLast(2) + ["+"] }
            guard let last = parts.last, !last.isEmpty else { return nil }
            var modifiers: KeyChord.Modifiers = []
            for part in parts.dropLast() {
                switch part {
                case "cmd", "command": modifiers.insert(.command)
                case "shift": modifiers.insert(.shift)
                case "opt", "option", "alt": modifiers.insert(.option)
                case "ctrl", "control": modifiers.insert(.control)
                default: return nil
                }
            }
            let aliases = [
                "enter": "return", "esc": "escape", "backspace": "delete", "comma": ",", "plus": "+", "minus": "-",
            ]
            key = aliases[last] ?? last
            self.modifiers = modifiers
        }

        /// The selector a field editor runs for this key, for keys a field handles itself.
        var editorCommand: Selector? {
            guard modifiers.isEmpty || modifiers == .shift else { return nil }
            switch key {
            case "up": return #selector(NSResponder.moveUp(_:))
            case "down": return #selector(NSResponder.moveDown(_:))
            case "left": return #selector(NSResponder.moveLeft(_:))
            case "right": return #selector(NSResponder.moveRight(_:))
            case "return": return #selector(NSResponder.insertNewline(_:))
            case "escape": return #selector(NSResponder.cancelOperation(_:))
            case "tab":
                return modifiers == .shift
                    ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
            case "delete": return #selector(NSResponder.deleteBackward(_:))
            default: return nil
            }
        }

        /// The key's virtual key code and characters, for views that read key events.
        var event: (code: UInt16, characters: String)? {
            switch key {
            case "return": (36, "\r")
            case "escape": (53, "\u{1B}")
            case "tab": (48, "\t")
            case "delete": (51, "\u{7F}")
            case "up": (126, String(UnicodeScalar(UInt16(NSUpArrowFunctionKey)).map(Character.init) ?? " "))
            case "down": (125, String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " "))
            case "left": (123, String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey)).map(Character.init) ?? " "))
            case "right": (124, String(UnicodeScalar(UInt16(NSRightArrowFunctionKey)).map(Character.init) ?? " "))
            case "space": (49, " ")
            default: key.count == 1 ? (0, key) : nil
            }
        }
    }

    /// Types one character into whatever has the keyboard: a card's field, a form field, or the
    /// search field, which reports it to the panel as a keystroke.
    private func type(_ character: Character) {
        if let editor = focusedEditor(), !isQueryEditor(editor) {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        let field = panel.surface.queryField
        let text = field.text + String(character)
        field.text = text
        panel.queryField(field, didChangeText: text)
    }

    private func press(_ press: KeyPress) {
        let field = panel.surface.queryField
        // A card or a form field has the keyboard: it handles its own keys, and Command chords go
        // to the panel, which closes the action card on Command-K.
        if let overlay = panel.surface.overlay {
            if press.modifiers.contains(.command) {
                _ = panel.queryField(
                    field, perform: command(for: press) ?? .chord(KeyChord(press.key, press.modifiers)))
            } else if let editor = focusedEditor(), let selector = press.editorCommand {
                editor.doCommand(by: selector)
            } else if let view = overlay.focusView, let key = press.event,
                let event = LocalKeyEvents.keyDown(characters: key.characters, keyCode: key.code, modifiers: [])
            {
                view.keyDown(with: event)
            }
            return
        }
        if let editor = focusedEditor(), !isQueryEditor(editor) {
            if press.modifiers.contains(.command) {
                _ = panel.queryField(
                    field, perform: command(for: press) ?? .chord(KeyChord(press.key, press.modifiers)))
            } else if let selector = press.editorCommand {
                editor.doCommand(by: selector)
            } else if press.key.count == 1 || press.key == "space" {
                let text = press.key == "space" ? " " : press.key
                editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return
        }
        // The search field moves Tab into a command's argument chips before the panel sees it.
        if press.key == "tab", press.modifiers.isEmpty, !field.arguments.isEmpty {
            field.focusArgument(0)
            return
        }
        if press.key == "delete", press.modifiers.isEmpty, !field.text.isEmpty {
            let text = String(field.text.dropLast())
            field.text = text
            panel.queryField(field, didChangeText: text)
            return
        }
        if let command = command(for: press) {
            _ = panel.queryField(field, perform: command)
        } else if press.modifiers.isEmpty, press.key == "space" {
            type(" ")
        } else if press.modifiers.isEmpty || press.modifiers == .shift, press.key.count == 1 {
            type(Character(press.modifiers == .shift ? press.key.uppercased() : press.key))
        }
    }

    /// The panel's command for a key, as the search field reports it.
    private func command(for press: KeyPress) -> QueryCommand? {
        let modifiers = press.modifiers
        switch press.key {
        case "up": return modifiers == .command ? .moveToPreviousSection : .moveUp
        case "down": return modifiers == .command ? .moveToNextSection : .moveDown
        case "left": return .moveLeft
        case "right": return .moveRight
        case "return": return .submit(modifiers)
        case "escape": return .cancel(modifiers)
        case "tab": return modifiers.contains(.shift) ? .completeBackward : .complete
        case "delete": return panel.surface.queryField.text.isEmpty ? .deleteOnEmpty : nil
        case "n" where modifiers == .control: return .moveDown
        case "p" where modifiers == .control: return .moveUp
        default: return modifiers.contains(.command) ? .chord(KeyChord(press.key, modifiers)) : nil
        }
    }

    private func focusedEditor() -> NSTextView? {
        panel.surface.panel.firstResponder as? NSTextView
    }

    private func isQueryEditor(_ editor: NSTextView) -> Bool {
        editor === panel.surface.queryField.textField.currentEditor()
    }

    /// Drops key events from the hardware while the scenario runs.
    private func ignoreHardwareKeys(_ ignore: Bool) {
        if ignore, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
        } else if !ignore, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: Waiting

    private func waitUntilIdle(_ seconds: Double) async -> String? {
        let limit = ContinuousClock.now + .milliseconds(Int(min(seconds, remainingSeconds) * 1000))
        var quiet = 0
        while ContinuousClock.now < limit {
            quiet = panel.isIdle ? quiet + 1 : 0
            // Idle on two checks in a row, so work that finishes and starts more is not missed.
            if quiet >= 2 { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if panel.isIdle { return nil }
        var busy: [String] = []
        if panel.top.isBusy { busy.append("the \(panel.topPageKind) page is busy") }
        if panel.surface.isLoading { busy.append("the loading bar shows") }
        if panel.runtime.pipeline.activeRunCount > 0 { busy.append("a run is under way") }
        if panel.surface.isAnimatingHeight { busy.append("the glass is animating") }
        return "not idle after \(seconds) s: " + busy.joined(separator: ", ")
    }

    // MARK: Checking

    func check(_ expected: ScenarioExpectation) -> String? {
        var problems: [String] = []
        let titles = panel.shownTitles
        if let rows = expected.rows, rows != titles { problems.append("rows were \(titles), expected \(rows)") }
        if let include = expected.rowsInclude {
            let missing = include.filter { !titles.contains($0) }
            if !missing.isEmpty { problems.append("rows lack \(missing); rows were \(titles)") }
        }
        if let count = expected.rowCount, count != titles.count {
            problems.append("\(titles.count) rows, expected \(count)")
        }
        if let selection = expected.selection, panel.selectedTitle != selection {
            problems.append("selection was \(Self.quoted(panel.selectedTitle)), expected \"\(selection)\"")
        }
        let toast = panel.surface.actionBar.toast?.text
        if let expectedToast = expected.toast, toast != expectedToast {
            problems.append("toast was \(Self.quoted(toast)), expected \"\(expectedToast)\"")
        }
        if expected.noToast == true, let toast { problems.append("a toast shows: \"\(toast)\"") }
        if let title = expected.title, (panel.top.title ?? "") != title {
            problems.append("title was \(Self.quoted(panel.top.title)), expected \"\(title)\"")
        }
        let ghost = panel.surface.queryField.ghostText
        if let expectedGhost = expected.ghost, ghost != expectedGhost {
            problems.append("ghost text was \"\(ghost)\", expected \"\(expectedGhost)\"")
        }
        let query = panel.surface.queryField.text
        if let expectedQuery = expected.query, query != expectedQuery {
            problems.append("query was \"\(query)\", expected \"\(expectedQuery)\"")
        }
        if let page = expected.page, panel.topPageKind != page {
            problems.append("page was \(panel.topPageKind), expected \(page)")
        }
        if let text = expected.detailIncludes, !(panel.shownDetailText ?? "").contains(text) {
            problems.append(
                "detail lacks \"\(text)\"; it shows \(Self.quoted(panel.shownDetailText.map { String($0.prefix(80)) }))"
            )
        }
        if let actions = expected.actions {
            if panel.surface.overlay !== panel.actionCard {
                problems.append("the action panel is not open")
            } else if panel.actionEntries.map(\.title) != actions {
                problems.append("actions were \(panel.actionEntries.map(\.title)), expected \(actions)")
            }
        }
        if let fields = expected.fieldErrors {
            let shown = ((panel.top as? FormPageController)?.errors.keys).map { Set($0) } ?? []
            if shown != Set(fields) {
                problems.append("fields with errors were \(shown.sorted()), expected \(fields.sorted())")
            }
        }
        if let card = expected.card {
            let shown = panel.pendingCard?.content.title ?? ""
            if shown != card { problems.append("the card was \(Self.quoted(shown)), expected \"\(card)\"") }
        }
        if let visible = expected.visible, panel.isPanelVisible != visible {
            problems.append(visible ? "the panel is hidden" : "the panel shows")
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    private func fill(_ id: String, _ value: String) -> String? {
        guard let form = panel.top as? FormPageController else { return "the top page is not a form" }
        guard let field = form.page.fields.first(where: { $0.id == id }) else { return "the form has no field \(id)" }
        switch field.kind {
        case .checkbox: form.fill(id, .bool(value == "true"))
        case .tags: form.fill(id, .strings(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
        case .files: form.fill(id, .files(value.isEmpty ? [] : [URL(fileURLWithPath: value)]))
        default: form.fill(id, .text(value))
        }
        return nil
    }

    // MARK: Capturing

    private func capture(_ name: String, key: Bool) async -> String? {
        guard panel.isPanelVisible else { return "the panel is hidden" }
        let window = panel.surface.panel
        let frame = window.frame
        // During a clip the wallpaper is already up and the panel already key.
        let key = key && recording == nil
        let backdrop = recording == nil ? makeBackdrop?(frame) : nil
        if let backdrop {
            backdrop.orderFrontRegardless()
            backdrop.order(.below, relativeTo: window.windowNumber)
        }
        defer { backdrop?.close() }
        panel.surface.updateHeight(animated: false)
        let resignHandler = window.onResignKey
        if key {
            // Key status only for the picture; giving it back must not dismiss the panel.
            window.onResignKey = nil
            window.makeKey()
            try? await Task.sleep(for: .milliseconds(120))
        }
        let image = await captureWithin(frame, seconds: min(5, remainingSeconds))
        if key {
            NSApp.deactivate()
            window.resignKey()
            window.onResignKey = resignHandler
        }
        guard let image else { return "the capture failed or timed out" }
        let file = output.appending(path: "captures/\(name).png")
        do {
            try PanelSnapshot.writePNG(image, to: file)
        } catch {
            return "cannot write \(file.path): \(error)"
        }
        captures.append(file.path)
        return nil
    }

    private func captureWithin(_ frame: CGRect, seconds: Double) async -> CGImage? {
        let capture = capture
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            let work = Task { @MainActor in answer.resume(try? await capture(frame)) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                work.cancel()
                answer.resume(nil)
            }
        }
    }

    /// Resumes a continuation once: with the capture, or with nil when the time ran out first.
    private final class Answer {
        private var continuation: CheckedContinuation<CGImage?, Never>?

        init(_ continuation: CheckedContinuation<CGImage?, Never>) {
            self.continuation = continuation
        }

        func resume(_ image: CGImage?) {
            continuation?.resume(returning: image)
            continuation = nil
        }
    }

    // MARK: Output

    private func write(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try encoder.encode(result).write(to: output.appending(path: "result.json"), options: .atomic)
        } catch {
            log("cannot write result.json: \(error)")
        }
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "\"\($0)\"" } ?? "nothing"
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
