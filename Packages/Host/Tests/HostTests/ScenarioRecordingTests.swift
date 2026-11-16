import AppKit
import Foundation
import Host
import Kit
import KitTesting
import Testing

/// The `record` and `stopRecording` steps, with a fake recorder: nothing is shown, recorded or
/// encoded.
@Suite("Scenario recording", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ScenarioRecordingTests {
    private func makeRunner(_ fixture: PanelFixture, recorder: FakeRecorder?) -> ScenarioRunner {
        let output = fixture.runtime.fakes.storage.root.appending(path: "scenario-out", directoryHint: .isDirectory)
        let runner = ScenarioRunner(panel: fixture.panel, output: output, placesInCorner: false)
        runner.capture = { _ in ScenarioTests.solidImage() }
        runner.log = { _ in }
        runner.recorder = recorder
        return runner
    }

    @Test func recordStepsDecode() throws {
        let json = """
            {"name": "clip", "steps": [
              {"record": {"name": "type-dark", "appearance": "dark", "backdrop": "none", "idle": 30, "pace": 0.5,
                          "lead": 0.2, "frameRate": 60}},
              {"record": {"name": "plain"}},
              {"stopRecording": true},
              {"stopRecording": {"tail": 1.5, "poster": 2.25, "webMaxBytes": 1000, "gifWidth": 900, "gifMaxBytes": 2000}},
              {"still": "settings-dark"}
            ]}
            """
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        #expect(
            scenario.steps == [
                .record(
                    ScenarioRecording(
                        name: "type-dark", appearance: .dark, backdrop: .none, idle: 30, pace: 0.5, lead: 0.2,
                        frameRate: 60)),
                .record(ScenarioRecording(name: "plain")),
                .stopRecording(ScenarioClipOutput()),
                .stopRecording(
                    ScenarioClipOutput(tail: 1.5, poster: 2.25, webMaxBytes: 1000, gifWidth: 900, gifMaxBytes: 2000)),
                .still("settings-dark"),
            ])
        #expect(ScenarioStep.still("x").name == "still")
        #expect(ScenarioRecording(name: "plain").idle == 120, "a clip waits for two idle minutes by default")
        for bad in [
            #"{"record": {"name": "../out"}}"#, #"{"record": {"name": ""}}"#, #"{"record": {"name": "x", "pace": -1}}"#,
            #"{"stopRecording": false}"#, #"{"stopRecording": {"tail": -2}}"#, #"{"still": "../pane"}"#,
            #"{"still": ""}"#,
        ] {
            #expect(throws: DecodingError.self, "\(bad)") {
                try JSONDecoder().decode(Scenario.self, from: Data(#"{"name": "x", "steps": [\#(bad)]}"#.utf8))
            }
        }
    }

    @Test func pausesFollowAPersonAtTheKeyboard() {
        #expect(ScenarioPacing.pause(before: .type("a"), after: .summon) == 0.3)
        #expect(ScenarioPacing.pause(before: .type("a"), after: .type("b")) == 0)
        #expect(ScenarioPacing.pause(before: .press("down"), after: .press("down")) == 0.24)
        #expect(ScenarioPacing.pause(before: .press("down"), after: .type("a")) == 0.42)
        #expect(ScenarioPacing.pause(before: .press("cmd+k"), after: nil) == 0.5)
        #expect(ScenarioPacing.pause(before: .expect(ScenarioExpectation()), after: nil) == 0)
        #expect(ScenarioPacing.pause(before: .still("pane"), after: .summon) == 0)
        #expect(ScenarioPacing.pause(beforeCharacter: "a", at: 0) == 0, "the step's own pause covers the first")
        let gaps = (1..<9).map { ScenarioPacing.pause(beforeCharacter: "a", at: $0) }
        #expect(gaps.allSatisfy { (0.09...0.16).contains($0) })
        #expect(Set(gaps).count > 3, "people do not type evenly")
        #expect(ScenarioPacing.pause(beforeCharacter: " ", at: 1) > ScenarioPacing.pause(beforeCharacter: "a", at: 1))
    }

    @Test func aClipPlaysItsStepsAtAPersonsPace() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        let steps: [ScenarioStep] = [
            .record(ScenarioRecording(name: "clip", lead: 0)), .type("Not"), .press("down"),
            .expect(ScenarioExpectation(query: "Not")), .stopRecording(ScenarioClipOutput(tail: 0)),
        ]
        let started = ContinuousClock.now
        let result = await runner.run(Scenario(name: "paced", steps: steps))
        let elapsed = ContinuousClock.now - started
        #expect(result.passed, "\(result.reason ?? "")")
        // 0.3 before typing, two gaps between three characters, 0.42 before the press.
        #expect(elapsed >= .milliseconds(900))
        #expect(recorder.started.map(\.name) == ["clip"])
        #expect(recorder.steps == ["record", "type", "press", "expect"])
        #expect(recorder.stopped == [ScenarioClipOutput(tail: 0)])
        #expect(result.captures == ["/clips/clip.mp4"], "the clip's files are listed with the captures")

        let quick = ContinuousClock.now
        let unpaced = await runner.run(
            Scenario(
                name: "unpaced",
                steps: [
                    .record(ScenarioRecording(name: "fast", pace: 0, lead: 0)), .type("Notes"), .press("down"),
                    .stopRecording(ScenarioClipOutput(tail: 0)),
                ]))
        #expect(unpaced.passed, "\(unpaced.reason ?? "")")
        // Against the paced run, so a busy machine slows both alike.
        #expect(ContinuousClock.now - quick < elapsed / 2, "pace 0 plays the steps at once")
    }

    @Test func inputDuringAClipThrowsItOutAndStopsTheRun() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        recorder.inputAfterSteps = 2
        let runner = makeRunner(fixture, recorder: recorder)
        let result = await runner.run(
            Scenario(
                name: "touched",
                steps: [
                    .record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .type("a"), .press("down"),
                    .stopRecording(ScenarioClipOutput(tail: 0)),
                ]))
        #expect(!result.passed)
        #expect(result.reason == "step 2 type: input arrived during the clip, so it was thrown out")
        #expect(recorder.cancelled == 1)
        #expect(recorder.stopped.isEmpty)
        #expect(result.steps.count == 2, "nothing runs after the input")
    }

    @Test func aFailedStepDuringAClipThrowsItOut() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        let result = await runner.run(
            Scenario(
                name: "wrong",
                steps: [
                    .record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .type("Plain"),
                    .expect(ScenarioExpectation(selection: "Echo")), .stopRecording(ScenarioClipOutput(tail: 0)),
                ]))
        #expect(!result.passed)
        #expect(result.reason?.hasPrefix("step 3 expect:") == true)
        #expect(recorder.cancelled == 1)
        #expect(recorder.stopped.isEmpty)
    }

    @Test func aClipLastsAcrossRunsUntilItStops() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        let first = await runner.run(
            Scenario(name: "one", steps: [.record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .type("N")]))
        #expect(first.passed)
        // A caller such as the app runs its own steps here, between two stretches of the file.
        let second = await runner.run(
            Scenario(name: "two", steps: [.type("ot"), .stopRecording(ScenarioClipOutput(tail: 0))]))
        #expect(second.passed, "\(second.reason ?? "")")
        #expect(recorder.steps == ["record", "type", "type"])
        #expect(recorder.stopped.count == 1)
        #expect(recorder.cancelled == 0)
    }

    @Test func recordingNeedsARecorderAndAStart() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let none = await makeRunner(fixture, recorder: nil).run(
            Scenario(name: "none", steps: [.record(ScenarioRecording(name: "clip"))]))
        #expect(none.reason?.contains("this build cannot record") == true)

        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        let unstarted = await runner.run(Scenario(name: "stop", steps: [.stopRecording(ScenarioClipOutput())]))
        #expect(unstarted.reason == "step 1 stopRecording: no clip is recording")

        recorder.startProblem = "the Mac was idle for 3 s and this clip needs 120 s"
        let busy = await runner.run(Scenario(name: "busy", steps: [.record(ScenarioRecording(name: "clip"))]))
        #expect(busy.reason == "step 1 record: the Mac was idle for 3 s and this clip needs 120 s")
        #expect(recorder.cancelled == 0, "a clip that never started has nothing to throw out")
    }

    @Test func aFileThatEndsWhileRecordingFails() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        let folder = fixture.runtime.fakes.storage.root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "open-clip.json")
        try Data(#"{"name": "open", "steps": [{"record": {"name": "clip", "pace": 0, "lead": 0}}]}"#.utf8)
            .write(to: file)
        #expect(await runner.run(file: file) == false)
        #expect(recorder.cancelled == 1)
    }

    @Test func aCaptureDuringAClipKeepsTheClipsBackdropAndKeyStatus() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        var backdrops = 0
        runner.makeBackdrop = { _ in
            backdrops += 1
            return nil
        }
        let result = await runner.run(
            Scenario(
                name: "still",
                steps: [
                    .record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .capture(name: "mid", key: true),
                    .stopRecording(ScenarioClipOutput(tail: 0)), .capture(name: "after", key: false),
                ]))
        #expect(result.passed, "\(result.reason ?? "")")
        #expect(backdrops == 1, "only the capture after the clip adds its own backdrop")
    }

    @Test func aStillDuringAClipCapturesTheWholeRecordedAreaEvenWithThePanelHidden() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        var captured: [CGRect] = []
        runner.capture = { rect in
            captured.append(rect)
            return ScenarioTests.solidImage()
        }
        let result = await runner.run(
            Scenario(
                name: "still",
                steps: [
                    .record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .dismiss, .still("pane-dark"),
                    .stopRecording(ScenarioClipOutput(tail: 0)),
                ]))
        #expect(result.passed, "\(result.reason ?? "")")
        #expect(captured == [FakeRecorder.canvas], "the still covers the clip's area, not the panel's frame")
        let still = runner.output.appending(path: "captures/pane-dark.png").path
        #expect(result.captures == [still, "/clips/clip.mp4"])
        #expect(FileManager.default.fileExists(atPath: still))
    }

    @Test func aStillOutsideAClipFails() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let runner = makeRunner(fixture, recorder: FakeRecorder())
        let result = await runner.run(Scenario(name: "loose", steps: [.still("pane")]))
        #expect(result.reason == "step 1 still: a still is taken during a clip; put a record step before it")
    }

    @Test func inputDuringAStillThrowsTheClipOut() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let recorder = FakeRecorder()
        let runner = makeRunner(fixture, recorder: recorder)
        runner.capture = { _ in
            recorder.inputArrived = true
            return ScenarioTests.solidImage()
        }
        let result = await runner.run(
            Scenario(
                name: "touched",
                steps: [
                    .record(ScenarioRecording(name: "clip", pace: 0, lead: 0)), .still("pane"),
                    .stopRecording(ScenarioClipOutput(tail: 0)),
                ]))
        #expect(result.reason == "step 2 still: input arrived during the clip, so it was thrown out")
        #expect(result.captures.isEmpty, "a still taken as input arrived is not kept")
        #expect(recorder.cancelled == 1)
    }

    @Test func theWindowsAClipShowsAreThisAppsWindowsInItsAreaFrontToBack() throws {
        _ = NSApplication.shared
        // Far off every screen, borderless so AppKit does not move them, and fully transparent.
        let canvas = CGRect(x: -41000, y: -41000, width: 940, height: 740)
        func window(_ frame: CGRect, panel: Bool = false) -> NSWindow {
            let made =
                panel
                ? NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
                : NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            made.isReleasedWhenClosed = false
            made.alphaValue = 0
            return made
        }
        let launcher = window(CGRect(x: -40900, y: -40900, width: 400, height: 300))
        let back = window(CGRect(x: -40980, y: -40980, width: 900, height: 640))
        let front = window(CGRect(x: -40800, y: -40800, width: 200, height: 200))
        let elsewhere = window(CGRect(x: -51000, y: -51000, width: 200, height: 200))
        let otherPanel = window(CGRect(x: -40950, y: -40950, width: 200, height: 200), panel: true)
        let hidden = window(CGRect(x: -40950, y: -40950, width: 200, height: 200))
        let all = [launcher, back, front, elsewhere, otherPanel, hidden]
        defer {
            for made in all { made.close() }
        }
        for shown in [launcher, back, elsewhere, otherPanel, front] { shown.orderFrontRegardless() }
        #expect(ScenarioWindows.shown(in: canvas, besides: launcher) == [front, back])
    }
}

/// Records what the runner asked of it, and nothing else.
@MainActor final class FakeRecorder: ScenarioRecorder {
    /// The area the fake records while a clip runs.
    static let canvas = CGRect(x: 10, y: 20, width: 940, height: 740)
    var inputArrived = false
    private(set) var canvas: CGRect?
    var started: [ScenarioRecording] = []
    var steps: [String] = []
    var stopped: [ScenarioClipOutput] = []
    var cancelled = 0
    var startProblem: String?
    /// Input arrives once this many steps ran during the clip.
    var inputAfterSteps: Int?

    func start(_ recording: ScenarioRecording, panel: PanelController, folder: URL) async -> String? {
        if let startProblem { return startProblem }
        started.append(recording)
        canvas = Self.canvas
        return nil
    }

    func stepDidRun(_ step: ScenarioStep) {
        steps.append(step.name)
        if let inputAfterSteps, steps.count >= inputAfterSteps { inputArrived = true }
    }

    func stop(_ output: ScenarioClipOutput) async -> Result<[String], ScenarioRecorderFailure> {
        stopped.append(output)
        canvas = nil
        return .success(["/clips/\(started.last?.name ?? "").mp4"])
    }

    func cancel() async {
        cancelled += 1
        canvas = nil
    }
}
