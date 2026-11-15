import SlickCoreC

/// A flag that stops a walk of the file index: a build, a rebuild, or a batch of events that
/// rescans whole folders.
///
/// Pass it to a call such as `FileIndex.build(_:cancellation:)` on the worker queue and call
/// `cancel()` from any thread, for example when the feature is turned off or the app quits. The
/// walker checks the flag once per folder, so the call returns within one folder listing per
/// walker thread and throws `CoreError.cancelled`. A stopped call publishes nothing: the index keeps
/// the snapshot it had.
public final class FileWalkCancellation: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer

    public init() throws(CoreError) {
        try RustCore.checkABI()
        var created: OpaquePointer?
        try CoreError.check(slick_files_cancel_new(&created))
        guard let created else { throw .nullPointer }
        handle = created
    }

    deinit {
        slick_files_cancel_free(handle)
    }

    /// Stops every walk that uses this flag, at its next folder.
    public func cancel() {
        slick_files_cancel_set(handle)
    }

    /// True once `cancel()` was called and until `reset()`.
    public var isCancelled: Bool {
        slick_files_cancel_is_set(handle) == 1
    }

    /// Clears the flag, so it can stop another walk.
    public func reset() {
        slick_files_cancel_reset(handle)
    }

    /// Lets `folders` more folder checks pass and then cancels, so a test stops a walk at a known
    /// point without racing a second thread. 0 cancels at once. For tests.
    public func cancel(afterFolders folders: Int) {
        slick_files_cancel_after(handle, UInt64(clamping: max(folders, 0)))
    }
}

extension FileIndex {
    /// Walks the roots of `configuration` into a new index, unless `cancellation` is cancelled
    /// first. Throws `CoreError.cancelled` then.
    public static func build(_ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation)
        throws(CoreError) -> (index: FileIndex, walk: FileWalkStats)
    {
        try RustCore.checkABI()
        var stats = SlickFilesWalkStats()
        var created: OpaquePointer?
        let status = withExtendedLifetime(cancellation) {
            configuration.withRaw { config, strings, count in
                slick_files_build_cancellable(config, strings, count, cancellation.handle, &created, &stats)
            }
        }
        try CoreError.check(status)
        guard let created else { throw .nullPointer }
        return (FileIndex(handle: created), FileWalkStats(stats))
    }

    /// Opens the index file at `path` when it was saved for the same roots and rules, and builds a
    /// new index otherwise. Opening is never interrupted; the build stops when `cancellation` is
    /// cancelled and throws `CoreError.cancelled`.
    public static func openOrBuild(
        at path: String, _ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation
    ) throws(CoreError) -> (index: FileIndex, info: FileIndexOpenInfo) {
        try RustCore.checkABI()
        var info = SlickFilesOpenInfo()
        var created: OpaquePointer?
        var path = path
        let status = withExtendedLifetime(cancellation) {
            path.withUTF8 { file in
                configuration.withRaw { config, strings, count in
                    slick_files_open_or_build_cancellable(
                        file.baseAddress, file.count, config, strings, count, cancellation.handle, &created, &info)
                }
            }
        }
        try CoreError.check(status)
        guard let created else { throw .nullPointer }
        return (FileIndex(handle: created), FileIndexOpenInfo(info))
    }

    /// Walks every root again and publishes the result, unless `cancellation` is cancelled first.
    /// A stopped rebuild throws `CoreError.cancelled` and keeps the snapshot the index had.
    @discardableResult
    public func rebuild(cancellation: FileWalkCancellation) throws(CoreError) -> FileWalkStats {
        var stats = SlickFilesWalkStats()
        let status = withExtendedLifetime(cancellation) {
            slick_files_rebuild_cancellable(handle, cancellation.handle, &stats)
        }
        try CoreError.check(status)
        return FileWalkStats(stats)
    }

    /// Applies one batch of FSEvents events, unless `cancellation` is cancelled while a rescan of
    /// a whole folder or a full walk runs. A stopped batch throws `CoreError.cancelled` and changes
    /// nothing; apply the events again, or rebuild, to catch up.
    @discardableResult
    public func apply(_ events: [FileEvent], cancellation: FileWalkCancellation) throws(CoreError)
        -> FileUpdateStats
    {
        var paths: [UInt8] = []
        var raw: [SlickFilesEvent] = []
        raw.reserveCapacity(events.count)
        for event in events {
            let start = paths.count
            paths.append(contentsOf: event.path.utf8)
            guard let s = UInt32(exactly: start), let n = UInt32(exactly: paths.count - start) else {
                throw .invalidArgument
            }
            raw.append(SlickFilesEvent(path_start: s, path_len: n, flags: event.flags, reserved: 0))
        }
        var stats = SlickFilesUpdateStats()
        let status = withExtendedLifetime(cancellation) {
            raw.withUnsafeBufferPointer { e in
                paths.withUnsafeBufferPointer { p in
                    slick_files_apply_cancellable(
                        handle, e.baseAddress, e.count, p.baseAddress, p.count, cancellation.handle, &stats)
                }
            }
        }
        try CoreError.check(status)
        return FileUpdateStats(stats)
    }
}
