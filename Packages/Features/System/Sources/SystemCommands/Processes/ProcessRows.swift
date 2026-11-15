import Foundation
import Kit

/// Processes the list never offers to quit.
nonisolated enum ProcessPolicy {
    /// User-session processes whose loss logs the user out, stops the screen from drawing, or breaks
    /// settings, the keychain or permissions until the next login. Most system daemons run as root
    /// and never reach the list, since it shows only the user's own processes.
    static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "loginwindow", "WindowServer", "cfprefsd", "distnoted", "lsd", "secd",
        "securityd", "trustd", "tccd", "UserEventAgent", "coreservicesd", "universalaccessd", "opendirectoryd",
        "logd", "runningboardd",
    ]

    /// True for this app, any copy of it, PID 1 and below, and the critical names above.
    static func isProtected(pid: Int32, name: String, path: String?, bundleID: String?, ownPID: Int32) -> Bool {
        if pid <= 1 || pid == ownPID || bundleID == Brand.bundleID { return true }
        if criticalNames.contains(name) { return true }
        if let path, criticalNames.contains(URL(filePath: path).lastPathComponent) { return true }
        return false
    }

    static func isProtected(_ process: ProcessSample, ownPID: Int32) -> Bool {
        isProtected(
            pid: process.pid, name: process.name, path: process.path, bundleID: process.bundleID, ownPID: ownPID)
    }

    static func isProtected(_ process: ProcessIdentity, ownPID: Int32) -> Bool {
        isProtected(
            pid: process.pid, name: process.name, path: process.path, bundleID: process.bundleID, ownPID: ownPID)
    }
}

/// One process as the list shows it.
nonisolated struct ProcessEntry: Hashable, Sendable {
    var sample: ProcessSample
    /// Percent of one core since the previous sample. Nil on the first sample, and for a process
    /// that started since then.
    var cpu: Double?
}

/// Turns snapshots into the list's rows, off the main thread.
nonisolated enum ProcessRows {
    static let namespace = "process"

    /// The processes to show, with CPU use, in the chosen order. Protected processes are left out,
    /// and so are processes without a Dock icon unless `showsBackground` is on.
    static func entries(
        _ snapshot: ProcessSnapshot, previous: ProcessSnapshot?, sort: ProcessSort, showsBackground: Bool
    ) -> [ProcessEntry] {
        let before = previous.map { previous in
            Dictionary(previous.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let elapsed = previous.map { snapshot.uptime > $0.uptime ? snapshot.uptime - $0.uptime : 0 } ?? 0
        let entries = snapshot.processes.compactMap { process -> ProcessEntry? in
            guard !ProcessPolicy.isProtected(process, ownPID: snapshot.ownPID) else { return nil }
            guard showsBackground || process.isRegularApp else { return nil }
            return ProcessEntry(
                sample: process, cpu: cpuPercent(process, before: before?[process.pid], elapsed: elapsed))
        }
        return sorted(entries, by: sort)
    }

    /// CPU use between two samples of the same process, as a percent of one core. Activity Monitor
    /// counts the same way, so a busy process with several threads can go above 100.
    static func cpuPercent(_ now: ProcessSample, before: ProcessSample?, elapsed: UInt64) -> Double? {
        guard let before, before.startTime == now.startTime, elapsed > 0, now.cpuTime >= before.cpuTime else {
            return nil
        }
        return Double(now.cpuTime - before.cpuTime) / Double(elapsed) * 100
    }

    /// CPU: busiest first, then most memory. Memory: most first. Name: alphabetical, as Finder
    /// sorts. Ties fall back to the name, then the PID, so the order is stable between refreshes.
    static func sorted(_ entries: [ProcessEntry], by sort: ProcessSort) -> [ProcessEntry] {
        entries.sorted { lhs, rhs in
            switch sort {
            case .cpu:
                let left = lhs.cpu ?? -1
                let right = rhs.cpu ?? -1
                if left != right { return left > right }
                if lhs.sample.memory != rhs.sample.memory { return lhs.sample.memory > rhs.sample.memory }
            case .memory:
                if lhs.sample.memory != rhs.sample.memory { return lhs.sample.memory > rhs.sample.memory }
            case .name:
                break
            }
            let order = lhs.sample.name.localizedStandardCompare(rhs.sample.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.sample.pid < rhs.sample.pid
        }
    }

    /// The rows, in order. The rank hint repeats the order, so it holds while the user types.
    @concurrent static func rows(
        _ snapshot: ProcessSnapshot, previous: ProcessSnapshot?, sort: ProcessSort, showsBackground: Bool,
        locale: Locale
    ) async -> [Row] {
        let entries = entries(snapshot, previous: previous, sort: sort, showsBackground: showsBackground)
        return entries.enumerated().map { index, entry in
            row(entry, rank: Double(entries.count - index), locale: locale)
        }
    }

    static func row(_ entry: ProcessEntry, rank: Double, locale: Locale) -> Row {
        let process = entry.sample
        var accessories: [Accessory] = []
        if let cpu = entry.cpu { accessories.append(.text(Strings.Processes.cpu(cpu, locale: locale))) }
        accessories.append(.text(Strings.Processes.memory(process.memory, locale: locale)))
        let name = process.displayName
        var keywords = [String(process.pid)]
        if let path = process.path {
            let executable = URL(filePath: path).lastPathComponent
            if executable != name { keywords.append(executable) }
        }
        if let bundleID = process.bundleID { keywords.append(bundleID) }
        return Row(
            id: ItemID(namespace, "\(process.pid)-\(process.startTime)"), title: name,
            subtitle: Strings.Processes.subtitle(pid: process.pid), icon: icon(process), accessories: accessories,
            keywords: keywords, payload: Payload(process.identity), rankHint: rank, memory: .never)
    }

    static func icon(_ process: ProcessSample) -> Icon {
        if let bundleID = process.bundleID { return .app(bundleID: bundleID) }
        if let bundlePath = process.bundlePath { return .file(path: bundlePath) }
        return .symbol("gearshape")
    }
}
