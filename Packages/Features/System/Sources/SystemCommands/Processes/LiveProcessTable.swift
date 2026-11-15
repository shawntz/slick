import AppKit
import Darwin
import Synchronization

/// The user's real processes, from `libproc`. Used only when the app runs for a person.
///
/// - Listing: `proc_listpids` with `PROC_UID_ONLY` for the user's own processes, since only those
///   can be quit without an administrator. `proc_pidinfo` gives the name, owner and start time,
///   `proc_pid_rusage` the CPU time and the physical footprint, which is the memory figure
///   Activity Monitor shows. `NSWorkspace.runningApplications` names the apps.
/// - Quitting: an app gets `NSRunningApplication.terminate()` or `forceTerminate()`; any other
///   process gets `SIGTERM` or `SIGKILL`. Before either, the PID is checked to still name the same
///   process, by its start time, and to belong to the user. PID 1 and below, and this app's own
///   PID, are refused outright.
/// - Each process's path and name are kept between snapshots, keyed by PID and start time, since
///   they never change. A refresh then costs two `libproc` calls per process instead of three.
nonisolated final class LiveProcessTable: ProcessTable {
    /// The path and name of each process seen in the last snapshot.
    private struct Known {
        var startTime: UInt64
        var path: String?
        var name: String
    }

    private let known = Mutex<[pid_t: Known]>([:])

    init() {}

    @concurrent func snapshot() async throws -> ProcessSnapshot {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let apps = Self.applications()
        let uid = getuid()
        let before = known.withLock { $0 }
        var seen: [pid_t: Known] = [:]
        let processes = Self.pids(ownedBy: uid).compactMap { pid -> ProcessSample? in
            guard let info = Self.bsdInfo(pid), info.pbi_uid == uid else { return nil }
            let start = Self.startTime(info)
            let identity: Known
            if let cached = before[pid], cached.startTime == start {
                identity = cached
            } else {
                let path = Self.executablePath(pid)
                identity = Known(startTime: start, path: path, name: Self.processName(info, path: path))
            }
            seen[pid] = identity
            return Self.sample(pid, known: identity, apps: apps, timebase: timebase)
        }
        known.withLock { $0 = seen }
        return ProcessSnapshot(uptime: uptime, ownPID: getpid(), processes: processes)
    }

    @concurrent func quit(_ process: ProcessIdentity) async throws {
        try Self.verify(process)
        if process.isApplication, let app = NSRunningApplication(processIdentifier: process.pid) {
            guard app.terminate() else { throw SystemFailure.notFound }
        } else {
            try Self.send(SIGTERM, to: process.pid)
        }
    }

    @concurrent func forceQuit(_ process: ProcessIdentity) async throws {
        try Self.verify(process)
        if process.isApplication, let app = NSRunningApplication(processIdentifier: process.pid) {
            guard app.forceTerminate() else { throw SystemFailure.notFound }
        } else {
            try Self.send(SIGKILL, to: process.pid)
        }
    }

    // MARK: - Reading

    private struct AppInfo {
        var name: String?
        var bundleID: String?
        var bundlePath: String?
        var isRegular: Bool
    }

    private static func applications() -> [pid_t: AppInfo] {
        var apps: [pid_t: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            apps[app.processIdentifier] = AppInfo(
                name: app.localizedName, bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                isRegular: app.activationPolicy == .regular)
        }
        return apps
    }

    /// The PIDs of the user's processes.
    private static func pids(ownedBy uid: uid_t) -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    private static func sample(
        _ pid: pid_t, known: Known, apps: [pid_t: AppInfo], timebase: mach_timebase_info_data_t
    ) -> ProcessSample? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        let app = apps[pid]
        return ProcessSample(
            pid: pid, startTime: known.startTime, name: app?.name ?? known.name, path: known.path,
            bundleID: app?.bundleID, bundlePath: app?.bundlePath, isApplication: app?.bundlePath != nil,
            isRegularApp: app?.isRegular ?? false,
            cpuTime: nanoseconds(usage.ri_user_time &+ usage.ri_system_time, timebase),
            memory: usage.ri_phys_footprint)
    }

    /// CPU times are in Mach time units, which are not nanoseconds on Apple silicon.
    static func nanoseconds(_ ticks: UInt64, _ timebase: mach_timebase_info_data_t) -> UInt64 {
        guard timebase.denom > 0, timebase.numer != timebase.denom else { return ticks }
        let value = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return value < 9e18 ? UInt64(value) : UInt64(9e18)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// The long name the kernel keeps, else the short one, else the executable's file name.
    private static func processName(_ info: proc_bsdinfo, path: String?) -> String {
        let long = withUnsafeBytes(of: info.pbi_name) { cString($0) }
        if !long.isEmpty { return long }
        let short = withUnsafeBytes(of: info.pbi_comm) { cString($0) }
        if !short.isEmpty { return short }
        return path.map { URL(filePath: $0).lastPathComponent } ?? ""
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The text before the first zero byte.
    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: - Quitting

    /// What the kernel says about a PID just before a signal, read again rather than taken from the
    /// row.
    struct Current: Hashable, Sendable {
        var startTime: UInt64
        var uid: uid_t
        var name: String
        var path: String?
        var bundleID: String?
    }

    /// Throws unless the PID still names the same process, the user owns it, and it is not one the
    /// list protects. The protection is checked again here, on the live name, path and bundle ID,
    /// so a row whose payload names a harmless process can never end a protected one.
    private static func verify(_ process: ProcessIdentity) throws {
        let current = bsdInfo(process.pid).map { info in
            let path = executablePath(process.pid)
            return Current(
                startTime: startTime(info), uid: info.pbi_uid, name: processName(info, path: path), path: path,
                bundleID: NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier)
        }
        if let refusal = refusal(for: process, current: current, ownPID: getpid(), uid: getuid()) { throw refusal }
    }

    /// Why a process must not be signalled, or nil when it may be. Pure, so tests cover every rule
    /// without touching a real process.
    static func refusal(for process: ProcessIdentity, current: Current?, ownPID: pid_t, uid: uid_t)
        -> SystemFailure?
    {
        guard process.pid > 1, process.pid != ownPID else { return .protected }
        guard let current, current.startTime == process.startTime else { return .notFound }
        guard current.uid == uid else { return .failed(code: EPERM) }
        let isProtected =
            ProcessPolicy.isProtected(process, ownPID: ownPID)
            || ProcessPolicy.isProtected(
                pid: process.pid, name: current.name, path: current.path, bundleID: current.bundleID, ownPID: ownPID)
        return isProtected ? .protected : nil
    }

    /// Sends a signal to exactly one process. The PID was verified to be above 1, so this can never
    /// reach a process group or every process.
    private static func send(_ signal: Int32, to pid: pid_t) throws {
        guard pid > 1 else { throw SystemFailure.failed(code: EPERM) }
        guard kill(pid, signal) == 0 else {
            let code = errno
            throw code == ESRCH ? SystemFailure.notFound : SystemFailure.failed(code: code)
        }
    }
}
