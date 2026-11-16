import Darwin
import Foundation

/// Starts one process with `posix_spawn(2)`, in a process group of its own.
///
/// The child gets exactly three descriptors: standard input from `/dev/null` or from a pipe the
/// runner writes, and standard output and standard error into two pipes the runner reads.
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything else the app has open. Signal dispositions go
/// back to their defaults and the signal mask is cleared, so an app that ignores `SIGPIPE` does not
/// pass that on to the command.
nonisolated enum Spawn {
    /// The parent's ends of a child that started.
    struct Child: Sendable {
        let pid: pid_t
        /// The read end of standard output.
        let output: Int32
        /// The read end of standard error.
        let errors: Int32
        /// The write end of standard input, when the request had input to write.
        let input: Int32?
    }

    /// Why a spawn failed. Nothing started, so there is nothing to signal or reap.
    struct Failure: Error, Sendable {
        let code: Int32
        let reason: String

        init(_ code: Int32, reason: String? = nil) {
            self.code = code
            self.reason = reason ?? String(cString: strerror(code))
        }
    }

    /// The `posix_spawnattr_setflags(3)` flags of every spawn.
    static let flags = Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)

    /// Starts `executable` with `arguments` and `environment`, in `directory`.
    static func start(
        executable: URL, arguments: [String], environment: [String: String], directory: URL, hasInput: Bool
    ) -> Result<Child, Failure> {
        let words = [executable.path(percentEncoded: false)] + arguments
        if words.contains(where: { $0.utf8.contains(0) }) {
            return .failure(Failure(EINVAL, reason: "an argument holds a NUL character"))
        }
        let entries = environment.compactMap { key, value -> String? in
            guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0), !value.utf8.contains(0) else { return nil }
            return "\(key)=\(value)"
        }

        // Every descriptor made here is closed on the way out, except the parent's ends of a child
        // that started.
        var opened: [Int32] = []
        defer {
            for descriptor in opened { close(descriptor) }
        }
        func makePipe() throws(Failure) -> (read: Int32, write: Int32) {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw Failure(errno) }
            opened += ends
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            return (ends[0], ends[1])
        }
        func check(_ result: Int32) throws(Failure) {
            if result != 0 { throw Failure(result) }
        }

        do throws(Failure) {
            let output = try makePipe()
            let errors = try makePipe()
            let input = hasInput ? try makePipe() : nil

            var actions: posix_spawn_file_actions_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            if let input {
                try check(posix_spawn_file_actions_adddup2(&actions, input.read, STDIN_FILENO))
            } else {
                try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            }
            try check(posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, errors.write, STDERR_FILENO))
            try check(
                directory.withUnsafeFileSystemRepresentation { folder in
                    folder.map { posix_spawn_file_actions_addchdir(&actions, $0) } ?? EINVAL
                })

            var attributes: posix_spawnattr_t?
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            var everySignal = sigset_t()
            var noSignal = sigset_t()
            sigfillset(&everySignal)
            sigemptyset(&noSignal)
            try check(posix_spawnattr_setflags(&attributes, flags))
            // Group 0 makes the child the leader of a new group whose ID is its own process ID.
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawnattr_setsigdefault(&attributes, &everySignal))
            try check(posix_spawnattr_setsigmask(&attributes, &noSignal))

            var pid: pid_t = 0
            try check(
                withCStrings(words) { argv in
                    withCStrings(entries) { envp in
                        executable.withUnsafeFileSystemRepresentation { file in
                            file.map { posix_spawn(&pid, $0, &actions, &attributes, argv, envp) } ?? EINVAL
                        }
                    }
                })

            // The child has its copies. The parent keeps only its own ends.
            let kept = [output.read, errors.read] + (input.map { [$0.write] } ?? [])
            opened.removeAll { kept.contains($0) }
            for end in [output.read, errors.read] {
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            }
            return .success(Child(pid: pid, output: output.read, errors: errors.read, input: input?.write))
        } catch {
            return .failure(error)
        }
    }

    /// Calls `body` with a NULL-terminated array of C strings that lives as long as the call.
    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer {
            for pointer in pointers { free(pointer) }
        }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
