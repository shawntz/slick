import Foundation

/// Command-line options: `LauncherUIDemo <mode> [key=value ...]`.
struct DemoOptions {
    let mode: String
    private var values: [String: String] = [:]

    init(_ arguments: [String]) {
        mode = arguments.first ?? "shots"
        for argument in arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
    }

    func string(_ key: String, _ fallback: String) -> String { values[key] ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func doubles(_ key: String, _ fallback: [Double]) -> [Double] {
        values[key].map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
    }

    /// Where captures go: `out=<dir>`, else `UI_DEMO_OUT`, else the current directory.
    var outputDirectory: URL {
        let path =
            values["out"] ?? ProcessInfo.processInfo.environment["UI_DEMO_OUT"]
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
