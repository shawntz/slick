import Foundation
import Kit
import KitTesting
import Testing

@testable import Windows

/// Times the paths the budget names. Runs only with `WINDOWS_BENCHMARK=1`, best in a release
/// build: `scripts/swiftpm.sh Packages/Features/Windows test -c release -Xswiftc -enable-testing
/// --filter LayoutBenchmark`. Prints counts and microseconds only.
@MainActor
@Suite(
    "Layout benchmark", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["WINDOWS_BENCHMARK"] == "1"))
struct LayoutBenchmark {
    static let desk = [Displays.laptop, Displays.rightExternal]
    static let options = LayoutOptions(screenGap: 10, windowGap: 8)
    static let start = Frame(x: 300, y: 200, width: 800, height: 500)

    @Test func planningAFrame() {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var worst: (id: String, p99: Duration) = ("", .zero)
        for command in WindowCommands.layouts {
            var perCommand: [Duration] = []
            let request = LayoutRequest(
                command: command.id, layout: command.layout, options: Self.options,
                restoreFrames: ["1_1": Self.start])
            let state = WindowState(key: "1_1", frame: Self.start)
            for _ in 0..<5_000 {
                let began = clock.now
                let plan = LayoutPlanner.plan(request, window: state, displays: Self.desk)
                perCommand.append(clock.now - began)
                blackHole(plan)
            }
            let p99 = percentile(perCommand, 0.99)
            if p99 > worst.p99 { worst = (command.id, p99) }
            samples += perCommand
        }
        report("plan, all layouts", samples)
        print("benchmark: worst layout p99 \(worst.id) \(microseconds(worst.p99)) us")
        #expect(percentile(samples, 0.99) < .milliseconds(1))
    }

    @Test func oneArrangePassOnTheSimulatedDesktop() async throws {
        let desktop = SimulatedWindows(displays: Self.desk, windows: [WindowsHarness.editor])
        let clock = ContinuousClock()
        var samples: [Duration] = []
        let layouts = WindowCommands.halves + WindowCommands.quarters
        for index in 0..<4_000 {
            let command = layouts[index % layouts.count]
            let request = LayoutRequest(command: command.id, layout: command.layout, options: Self.options)
            let began = clock.now
            _ = try await desktop.arrangeFocusedWindow(request)
            samples.append(clock.now - began)
        }
        report("arrange pass, simulated, wall", samples)
    }

    @Test func theFeaturesMainActorWork() {
        // What a command does on the main actor around the service call: read settings, build the
        // request, then record the result.
        let fakes = FakeServices()
        let settings = fakes.context(featureID: "windows").settings
        var memory = RestoreMemory()
        for index in 0..<RestoreMemory.capacity {
            let frame = Frame(x: Double(index), y: 0, width: 100, height: 100)
            memory.record(Moved(window: "1_\(index)", before: frame, after: frame, step: 0))
        }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for index in 0..<10_000 {
            let began = clock.now
            let request = LayoutRequest(
                command: "left-half", layout: .half(.left), options: WindowsSettings.options(settings),
                restoreFrames: memory.frames)
            let frame = Frame(x: Double(index % 500), y: 0, width: 100, height: 100)
            memory.record(Moved(window: "1_\(index % 80)", before: frame, after: frame, step: 0))
            samples.append(clock.now - began)
            blackHole(request)
        }
        report("main actor work per command, full memory", samples)
    }

    @Test func aWholeCommandThroughTheHarness() async throws {
        let windows = WindowsHarness(displays: Self.desk)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for index in 0..<2_000 {
            let command = index.isMultiple(of: 2) ? "left-half" : "maximize"
            let began = clock.now
            try await windows.press(command)
            samples.append(clock.now - began)
        }
        report("whole command, harness, wall", samples)
    }

    // MARK: - Helpers

    private func report(_ name: String, _ samples: [Duration]) {
        print(
            "benchmark: \(name): n \(samples.count), p50 \(microseconds(percentile(samples, 0.5))) us, "
                + "p99 \(microseconds(percentile(samples, 0.99))) us, max \(microseconds(samples.max() ?? .zero)) us")
    }

    private func percentile(_ samples: [Duration], _ fraction: Double) -> Duration {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return .zero }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private func microseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.attoseconds) / 1e12 + Double(duration.components.seconds) * 1e6
        return String(format: "%.2f", value)
    }

    @inline(never) private func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }
}
