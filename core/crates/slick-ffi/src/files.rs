//! C ABI for the file index: the `slick_files_*` functions over `slick-files`.
//!
//! Four kinds of handle:
//! - `SlickFiles`, the index. Safe to use from any thread at once: searches read a snapshot and
//!   never wait for the writer, and one writer at a time applies events, rebuilds or saves. Build
//!   it off the main thread, because it walks the disk.
//! - `SlickFilesSession`, one search field's state: the searcher that narrows as the query grows,
//!   the hits of the last search, the snapshot they belong to, and reusable buffers. One thread at
//!   a time. A search allocates nothing once the session is warm.
//! - `SlickFilesSnapshot`, an immutable view that keeps entry ids meaningful after the index
//!   changes. Entry ids belong to one snapshot: resolve a hit with the session that returned it, or
//!   with the snapshot taken from that session.
//! - `SlickFilesCancel`, a flag that stops a walk. Pass it to a `_cancellable` function and set it
//!   from any thread; the walker checks it once per folder and the call returns
//!   `SLICK_STATUS_CANCELLED` without publishing anything. Free it after every call that uses it
//!   has returned.
//!
//! A search splits its work into parts and runs them with Grand Central Dispatch at the calling
//! thread's quality of service, inside Rust. Paths are bytes, as the file system stores them, and
//! lists of paths or names are separated by NUL bytes.

use crate::args::{bytes, handle, handle_mut, out, slice, text};
use crate::session::{SlickRange, write_ranges};
use crate::status::{SlickStatus, guard, guard_result};
use slick_files::{
    BrowseSort, Cancel, Cancelled, Config, EntryId, Event, FileHit, FileIndex, How, Kinds, LoadError, ParallelFor,
    Prefer, Rules, SearchOptions, Searcher, Serial, Snapshot, UpdateStats, walk::WalkStats,
};
use std::any::Any;
use std::ffi::{OsStr, c_void};
use std::os::unix::ffi::OsStrExt;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

/// No entry: `SlickFilesOptions.within` without a folder, `SlickFileEntry.parent` of a root.
pub const SLICK_FILES_NONE: u32 = u32::MAX;

/// `SlickFileHit.flags`, `SlickFileEntry.flags`: a folder.
pub const SLICK_FILES_ENTRY_DIR: u8 = 1;
/// Entry flag: a folder treated as one item, such as an app or a document package.
pub const SLICK_FILES_ENTRY_PACKAGE: u8 = 2;
/// Entry flag: a dot name or a name with the hidden flag.
pub const SLICK_FILES_ENTRY_HIDDEN: u8 = 4;
/// Entry flag: a symbolic link. Never followed.
pub const SLICK_FILES_ENTRY_SYMLINK: u8 = 8;
/// Entry flag: one of the index roots.
pub const SLICK_FILES_ENTRY_ROOT: u8 = 64;
/// Entry flag: a folder the walker could not list.
pub const SLICK_FILES_ENTRY_UNREADABLE: u8 = 128;

/// `SlickFileHit.how`: the query matched the name.
pub const SLICK_FILES_HOW_NAME: u8 = 0;
/// `SlickFileHit.how`: some tokens matched the name, the others folders above it.
pub const SLICK_FILES_HOW_ANCESTOR: u8 = 1;
/// `SlickFileHit.how`: the last token was the extension.
pub const SLICK_FILES_HOW_EXTENSION: u8 = 2;
/// `SlickFileHit.how`: one edit away from a word of the name.
pub const SLICK_FILES_HOW_TYPO: u8 = 3;
/// `SlickFileHit.how`: only filters, such as an extension or a path fragment.
pub const SLICK_FILES_HOW_FILTER: u8 = 4;
/// `SlickFileHit.how`: a child of a browsed folder.
pub const SLICK_FILES_HOW_BROWSE: u8 = 5;

/// `SlickFilesOptions.kinds`: files and folders.
pub const SLICK_FILES_KINDS_ALL: u8 = 0;
/// `SlickFilesOptions.kinds`: files only.
pub const SLICK_FILES_KINDS_FILES: u8 = 1;
/// `SlickFilesOptions.kinds`: folders only.
pub const SLICK_FILES_KINDS_FOLDERS: u8 = 2;
/// `SlickFilesOptions.prefer`: no kind is lifted.
pub const SLICK_FILES_PREFER_NEITHER: u8 = 0;
/// `SlickFilesOptions.prefer`: files rank higher inside each tier.
pub const SLICK_FILES_PREFER_FILES: u8 = 1;
/// `SlickFilesOptions.prefer`: folders rank higher inside each tier.
pub const SLICK_FILES_PREFER_FOLDERS: u8 = 2;
/// `SlickFilesOptions.browse_sort`: a folder listing without a filter in name order.
pub const SLICK_FILES_SORT_NAME: u8 = 0;
/// `SlickFilesOptions.browse_sort`: a folder listing without a filter, newest first.
pub const SLICK_FILES_SORT_MODIFIED: u8 = 1;

/// `SlickFilesOptions.flags`: return hidden entries the index holds.
pub const SLICK_FILES_SEARCH_HIDDEN: u8 = 1;
/// `SlickFilesOptions.flags`: never run the typo pass.
pub const SLICK_FILES_SEARCH_NO_TYPO: u8 = 2;
/// `SlickFilesOptions.flags`: run every part on the calling thread.
pub const SLICK_FILES_SEARCH_SERIAL: u8 = 4;

/// `SlickFilesConfig.flags`: start from the recommended rules (dependency, build and cache folders
/// skipped, bundles as leaves, `<home>/Library` skipped) and add the lists to them.
pub const SLICK_FILES_RULES_RECOMMENDED: u32 = 1;
/// `SlickFilesConfig.flags`: index dot names and names with the hidden flag.
pub const SLICK_FILES_RULES_INCLUDE_HIDDEN: u32 = 2;
/// `SlickFilesConfig.flags`: do not enter folders on another volume.
pub const SLICK_FILES_RULES_ONE_FILESYSTEM: u32 = 4;
/// `SlickFilesConfig.flags`: keep a root nested in another when the walk of the outer root never
/// enters it, because a skipped path, a skipped or hidden name or a package lies on the way, or the
/// root itself is skipped. iCloud Drive inside a skipped Library folder is the case. Without this
/// flag every nested root is dropped.
pub const SLICK_FILES_RULES_KEEP_UNREACHED_ROOTS: u32 = 8;

/// `SlickFilesListInfo.problem`: the folder was listed.
pub const SLICK_FILES_LIST_OK: u8 = 0;
/// `SlickFilesListInfo.problem`: the folder does not exist.
pub const SLICK_FILES_LIST_MISSING: u8 = 1;
/// `SlickFilesListInfo.problem`: the path names a file, or a symbolic link, which is never
/// followed.
pub const SLICK_FILES_LIST_NOT_FOLDER: u8 = 2;
/// `SlickFilesListInfo.problem`: reading the folder was not allowed.
pub const SLICK_FILES_LIST_DENIED: u8 = 3;
/// `SlickFilesListInfo.problem`: the folder could not be read for another reason.
pub const SLICK_FILES_LIST_FAILED: u8 = 4;

/// `SlickFilesOpenInfo.load_error`: the file opened.
pub const SLICK_FILES_LOAD_OK: u8 = 0;
/// `SlickFilesOpenInfo.load_error`: there was no index file.
pub const SLICK_FILES_LOAD_MISSING: u8 = 1;
/// `SlickFilesOpenInfo.load_error`: the file could not be read.
pub const SLICK_FILES_LOAD_IO: u8 = 2;
/// `SlickFilesOpenInfo.load_error`: the file is damaged.
pub const SLICK_FILES_LOAD_CORRUPT: u8 = 3;
/// `SlickFilesOpenInfo.load_error`: the file has another format version.
pub const SLICK_FILES_LOAD_VERSION: u8 = 4;
/// `SlickFilesOpenInfo.load_error`: the file was built for other roots or rules.
pub const SLICK_FILES_LOAD_MISMATCH: u8 = 5;

/// What to index, as spans into one byte buffer passed beside it, 48 bytes. Every list holds
/// items separated by a NUL byte.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesConfig {
    /// Absolute folders to index. Nested and repeated roots are dropped.
    pub roots_start: u32,
    /// Byte length of the roots list.
    pub roots_len: u32,
    /// Names skipped wherever they appear, compared without ASCII case. UTF-8.
    pub skip_names_start: u32,
    /// Byte length of the skipped names.
    pub skip_names_len: u32,
    /// Absolute paths skipped with everything below them.
    pub skip_paths_start: u32,
    /// Byte length of the skipped paths.
    pub skip_paths_len: u32,
    /// Folder extensions indexed but not entered, such as `app`. UTF-8.
    pub leaf_extensions_start: u32,
    /// Byte length of the leaf extensions.
    pub leaf_extensions_len: u32,
    /// The home folder, for the recommended rules. May be empty.
    pub home_start: u32,
    /// Byte length of the home folder.
    pub home_len: u32,
    /// Walker threads for a full build, 0 for the default.
    pub threads: u32,
    /// `SLICK_FILES_RULES_*`.
    pub flags: u32,
}

/// What a walk saw, 32 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesWalkStats {
    /// Folders listed.
    pub dirs: u64,
    /// Entries kept.
    pub entries: u64,
    /// Folders that could not be listed.
    pub unreadable: u64,
    /// Wall time, microseconds.
    pub elapsed_us: u64,
}

/// What `slick_files_open_or_build` did, 64 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesOpenInfo {
    /// The FSEvents id the opened file is current to; resume the stream after it. 0 after a build.
    pub event_id: u64,
    /// When the opened file was saved, Unix seconds. 0 after a build.
    pub saved_at: u64,
    /// Entries in the index.
    pub entries: u64,
    /// The walk, when the index was built.
    pub walk: SlickFilesWalkStats,
    /// 1 when the index came from the file, 0 when it was built.
    pub opened: u8,
    /// `SLICK_FILES_LOAD_*`: why the file was not used.
    pub load_error: u8,
    /// Zero.
    pub reserved: [u8; 6],
}

/// One FSEvents event: a span of the paths buffer and the event's flags, 16 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesEvent {
    /// Byte offset of the absolute path in the paths buffer.
    pub path_start: u32,
    /// Byte length of the path.
    pub path_len: u32,
    /// The FSEvents flags, unchanged.
    pub flags: u32,
    /// Zero.
    pub reserved: u32,
}

/// What one batch of events did, 48 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesUpdateStats {
    /// Events in the batch.
    pub events: u64,
    /// Events that needed no disk access.
    pub ignored: u64,
    /// Folders listed again.
    pub rescans: u64,
    /// Entries added.
    pub added: u32,
    /// Entries removed.
    pub removed: u32,
    /// Entries whose facts changed.
    pub changed: u32,
    /// 1 when the history was lost and every root was walked again.
    pub full: u8,
    /// 1 when a new snapshot was published.
    pub published: u8,
    /// Zero.
    pub reserved: [u8; 2],
    /// Wall time, microseconds.
    pub elapsed_us: u64,
}

/// Options for one search, 16 bytes. The hit buffer's capacity is the limit.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlickFilesOptions {
    /// Only entries strictly below this folder, or `SLICK_FILES_NONE`. An id of the snapshot the
    /// search runs on.
    pub within: u32,
    /// Current Unix time in seconds, for the recency lift. 0 turns the lift off.
    pub now: u32,
    /// `SLICK_FILES_KINDS_*`.
    pub kinds: u8,
    /// `SLICK_FILES_PREFER_*`.
    pub prefer: u8,
    /// `SLICK_FILES_SORT_*`.
    pub browse_sort: u8,
    /// `SLICK_FILES_SEARCH_*`.
    pub flags: u8,
    /// Zero.
    pub reserved: u32,
}

impl Default for SlickFilesOptions {
    fn default() -> Self {
        SlickFilesOptions {
            within: SLICK_FILES_NONE,
            now: 0,
            kinds: SLICK_FILES_KINDS_ALL,
            prefer: SLICK_FILES_PREFER_NEITHER,
            browse_sort: SLICK_FILES_SORT_NAME,
            flags: 0,
            reserved: 0,
        }
    }
}

/// One search result, 12 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFileHit {
    /// The entry, in the snapshot of the search.
    pub id: u32,
    /// Higher is better: 10,000 × tier + quality + lift.
    pub rank: i32,
    /// `SLICK_FILES_HOW_*`.
    pub how: u8,
    /// File tier, 0 (subsequence) to 7 (exact); 2 is the folder tier.
    pub tier: u8,
    /// `SLICK_FILES_ENTRY_*`.
    pub flags: u8,
    /// Depth below the filesystem root.
    pub depth: u8,
}

/// Facts about one entry, 24 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFileEntry {
    /// Size in bytes, exact below 2 GiB and rounded down to a MiB above. `u64::MAX` for a folder.
    pub size: u64,
    /// The parent folder, `SLICK_FILES_NONE` for a root.
    pub parent: u32,
    /// Modification time, Unix seconds.
    pub mtime: u32,
    /// Byte length of the name.
    pub name_len: u32,
    /// `SLICK_FILES_ENTRY_*`.
    pub flags: u8,
    /// Depth below the filesystem root.
    pub depth: u8,
    /// Zero.
    pub reserved: [u8; 2],
}

/// Facts about a snapshot, 40 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesInfo {
    /// Live entries.
    pub entries: u64,
    /// Slots, live or dead. Entry ids are below this.
    pub slots: u64,
    /// Changes every time the index publishes.
    pub generation: u64,
    /// Bytes on the heap.
    pub heap_bytes: u64,
    /// Bytes read through the mapped index file.
    pub mapped_bytes: u64,
}

/// What the last search did, 16 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesSearchStats {
    /// Entries the strict pass looked at.
    pub scanned: u64,
    /// 1 when the prefix pass filled the hits.
    pub prefix_only: u8,
    /// 1 when the search narrowed the previous one.
    pub narrowed: u8,
    /// 1 when the typo pass ran.
    pub typo_ran: u8,
    /// 1 when a folder query named a folder the index does not hold.
    pub not_indexed: u8,
    /// Zero.
    pub reserved: u32,
}

/// One child of a folder listed from disk, 24 bytes. Its name is a span of the names buffer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesListItem {
    /// Size in bytes, `u64::MAX` for a folder.
    pub size: u64,
    /// Byte offset of the name in the names buffer.
    pub name_start: u32,
    /// Byte length of the name.
    pub name_len: u32,
    /// Modification time, Unix seconds.
    pub mtime: u32,
    /// `SLICK_FILES_ENTRY_*`: folder, package, hidden or symbolic link.
    pub flags: u8,
    /// Zero.
    pub reserved: [u8; 3],
}

/// What `slick_files_list_folder` found, 24 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickFilesListInfo {
    /// Children the rules keep: the items written, or the room the items buffer needs.
    pub items: u64,
    /// Bytes of all their names: the room the names buffer needs.
    pub name_bytes: u64,
    /// `SLICK_FILES_LIST_*`.
    pub problem: u8,
    /// 1 when every entry was read; 0 when reading stopped partway and some may be missing.
    pub complete: u8,
    /// Zero.
    pub reserved: [u8; 6],
}

/// An opaque cancel flag for walks.
pub struct SlickFilesCancel {
    inner: Cancel,
}

/// The flag of calls made without one.
static NEVER: Cancel = Cancel::new();

/// An opaque file index.
pub struct SlickFiles {
    pub(crate) inner: FileIndex,
}

/// An opaque snapshot of a file index.
pub struct SlickFilesSnapshot {
    inner: Arc<Snapshot>,
}

/// An opaque search session.
pub struct SlickFilesSession {
    searcher: Searcher,
    hits: Vec<FileHit>,
    options: SearchOptions,
    /// The text of the last search, for highlights.
    query: String,
    ranges: Vec<(u32, u32)>,
    gcd: Gcd,
}

// ---- parallel parts on Grand Central Dispatch

unsafe extern "C" {
    /// libdispatch, part of libSystem. A NULL queue is `DISPATCH_APPLY_AUTO`: the system picks a
    /// concurrent queue at the calling thread's quality of service.
    fn dispatch_apply_f(
        iterations: usize,
        queue: *mut c_void,
        context: *mut c_void,
        work: extern "C" fn(*mut c_void, usize),
    );
}

/// Runs a search's parts with `dispatch_apply_f`. A panic inside a part is caught on the worker
/// thread and raised again on the calling thread, where the boundary guard turns it into a status.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Gcd {
    pub(crate) width: usize,
}

struct Job<'a> {
    f: &'a (dyn Fn(usize) + Sync),
    panic: OnceLock<Box<dyn Any + Send>>,
}

extern "C" fn run_part(context: *mut c_void, i: usize) {
    // SAFETY: `context` is the `Job` that `Gcd::for_each` keeps alive until `dispatch_apply_f`
    // returns, which is after every call of this function has returned. It is only read.
    let job = unsafe { &*(context as *const Job<'_>) };
    if let Err(p) = catch_unwind(AssertUnwindSafe(|| (job.f)(i))) {
        let _ = job.panic.set(p);
    }
}

impl ParallelFor for Gcd {
    fn width(&self) -> usize {
        self.width
    }

    fn for_each(&self, n: usize, f: &(dyn Fn(usize) + Sync)) {
        if n <= 1 || self.width <= 1 {
            Serial.for_each(n, f);
            return;
        }
        let job = Job {
            f,
            panic: OnceLock::new(),
        };
        // SAFETY: `run_part` matches the work function type, and `job` outlives the call, which
        // returns only after every iteration has finished. The parts only share `Sync` data.
        unsafe { dispatch_apply_f(n, std::ptr::null_mut(), &job as *const Job<'_> as *mut c_void, run_part) };
        if let Some(p) = job.panic.into_inner() {
            resume_unwind(p);
        }
    }
}

// ---- reading arguments

/// The items of a NUL-separated list, skipping empty ones.
fn list(b: &[u8]) -> impl Iterator<Item = &[u8]> {
    b.split(|&c| c == 0).filter(|s| !s.is_empty())
}

fn span(strings: &[u8], start: u32, len: u32) -> Result<&[u8], SlickStatus> {
    let start = start as usize;
    let end = start.checked_add(len as usize).ok_or(SlickStatus::InvalidArgument)?;
    strings.get(start..end).ok_or(SlickStatus::InvalidArgument)
}

fn path_of(b: &[u8]) -> PathBuf {
    PathBuf::from(OsStr::from_bytes(b))
}

fn utf8_list(b: &[u8]) -> Result<Vec<String>, SlickStatus> {
    list(b)
        .map(|s| {
            std::str::from_utf8(s)
                .map(str::to_string)
                .map_err(|_| SlickStatus::InvalidUtf8)
        })
        .collect()
}

fn config(c: &SlickFilesConfig, strings: &[u8]) -> Result<Config, SlickStatus> {
    let roots: Vec<PathBuf> = list(span(strings, c.roots_start, c.roots_len)?).map(path_of).collect();
    if roots.iter().any(|r| !r.is_absolute()) {
        return Err(SlickStatus::InvalidArgument);
    }
    let home = span(strings, c.home_start, c.home_len)?;
    let mut rules = if c.flags & SLICK_FILES_RULES_RECOMMENDED != 0 {
        Rules::recommended((!home.is_empty()).then(|| Path::new(OsStr::from_bytes(home))))
    } else {
        Rules {
            include_hidden: false,
            skip_names: Vec::new(),
            skip_paths: Vec::new(),
            leaf_extensions: Vec::new(),
            one_filesystem: false,
        }
    };
    rules.include_hidden = c.flags & SLICK_FILES_RULES_INCLUDE_HIDDEN != 0;
    rules.one_filesystem = c.flags & SLICK_FILES_RULES_ONE_FILESYSTEM != 0;
    rules
        .skip_names
        .extend(utf8_list(span(strings, c.skip_names_start, c.skip_names_len)?)?);
    rules
        .skip_paths
        .extend(list(span(strings, c.skip_paths_start, c.skip_paths_len)?).map(path_of));
    rules.leaf_extensions.extend(utf8_list(span(
        strings,
        c.leaf_extensions_start,
        c.leaf_extensions_len,
    )?)?);
    let mut config = Config::new(roots, rules);
    if c.threads > 0 {
        config.threads = (c.threads as usize).min(64);
    }
    config.keep_unreached_roots = c.flags & SLICK_FILES_RULES_KEEP_UNREACHED_ROOTS != 0;
    Ok(config)
}

/// The flag behind a cancel handle, or one that is never set for NULL.
fn stop<'a>(c: *const SlickFilesCancel) -> Result<&'a Cancel, SlickStatus> {
    if c.is_null() { Ok(&NEVER) } else { Ok(&handle(c)?.inner) }
}

fn cancelled(_: Cancelled) -> SlickStatus {
    SlickStatus::Cancelled
}

/// A path argument for a file or folder: not empty, without NUL bytes.
fn file_path<'a>(path: *const u8, len: usize) -> Result<&'a Path, SlickStatus> {
    let b = bytes(path, len)?;
    if b.is_empty() || b.contains(&0) {
        return Err(SlickStatus::InvalidArgument);
    }
    Ok(Path::new(OsStr::from_bytes(b)))
}

fn micros(d: std::time::Duration) -> u64 {
    u64::try_from(d.as_micros()).unwrap_or(u64::MAX)
}

fn walk_stats(s: &WalkStats) -> SlickFilesWalkStats {
    SlickFilesWalkStats {
        dirs: s.dirs as u64,
        entries: s.entries as u64,
        unreadable: s.unreadable as u64,
        elapsed_us: micros(s.elapsed),
    }
}

fn update_stats(s: &UpdateStats) -> SlickFilesUpdateStats {
    let small = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
    SlickFilesUpdateStats {
        events: s.events as u64,
        ignored: s.ignored as u64,
        rescans: s.rescans as u64,
        added: small(s.added),
        removed: small(s.removed),
        changed: small(s.changed),
        full: s.full as u8,
        published: s.published as u8,
        reserved: [0; 2],
        elapsed_us: micros(s.elapsed),
    }
}

/// Writes `value` to `ptr` when it is not NULL. Optional outputs use it.
fn put<T>(ptr: *mut T, value: T) -> Result<(), SlickStatus> {
    if !ptr.is_null() {
        *handle_mut(ptr)? = value;
    }
    Ok(())
}

fn index<'a>(i: *const SlickFiles) -> Result<&'a FileIndex, SlickStatus> {
    Ok(&handle(i)?.inner)
}

fn how(code: u8) -> Result<How, SlickStatus> {
    Ok(match code {
        SLICK_FILES_HOW_NAME => How::Name,
        SLICK_FILES_HOW_ANCESTOR => How::Ancestor,
        SLICK_FILES_HOW_EXTENSION => How::Extension,
        SLICK_FILES_HOW_TYPO => How::Typo,
        SLICK_FILES_HOW_FILTER => How::Filter,
        SLICK_FILES_HOW_BROWSE => How::Browse,
        _ => return Err(SlickStatus::InvalidArgument),
    })
}

fn snapshot_info(s: &Snapshot) -> SlickFilesInfo {
    SlickFilesInfo {
        entries: s.len() as u64,
        slots: s.slots() as u64,
        generation: s.generation(),
        heap_bytes: s.heap_bytes() as u64,
        mapped_bytes: s.mapped_bytes() as u64,
    }
}

/// Copies the absolute path of `id` in `snap` into the caller's buffer. With `cap` 0 it only
/// measures.
fn write_path(snap: &Snapshot, id: EntryId, ptr: *mut u8, cap: usize) -> Result<i32, SlickStatus> {
    let buf = out(ptr, cap)?;
    match snap.path_to_slice(id, buf) {
        Ok(n) => i32::try_from(n).map_err(|_| SlickStatus::InvalidArgument),
        Err(0) => Err(SlickStatus::InvalidArgument),
        Err(needed) if cap == 0 => i32::try_from(needed).map_err(|_| SlickStatus::InvalidArgument),
        Err(_) => Err(SlickStatus::BufferTooSmall),
    }
}

fn write_entry(snap: &Snapshot, id: EntryId, dst: *mut SlickFileEntry) -> Result<i32, SlickStatus> {
    let dst = handle_mut(dst)?;
    let e = snap.entry(id).ok_or(SlickStatus::InvalidArgument)?;
    *dst = SlickFileEntry {
        size: e.size.unwrap_or(u64::MAX),
        parent: e.parent,
        mtime: e.mtime,
        name_len: u32::try_from(e.name.len()).unwrap_or(u32::MAX),
        flags: e.flags,
        depth: e.depth,
        reserved: [0; 2],
    };
    Ok(SlickStatus::Ok as i32)
}

fn session_snapshot(s: &SlickFilesSession) -> Result<&Arc<Snapshot>, SlickStatus> {
    s.searcher.snapshot().ok_or(SlickStatus::InvalidArgument)
}

// ---- the index

/// Walks the roots of `config` (spans into `strings`) into a new index and stores it in `*out`.
/// Fills `*stats` when it is not NULL. Walks the disk: call it off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_build(
    config: *const SlickFilesConfig,
    strings: *const u8,
    strings_len: usize,
    out: *mut *mut SlickFiles,
    stats: *mut SlickFilesWalkStats,
) -> i32 {
    slick_files_build_cancellable(config, strings, strings_len, std::ptr::null(), out, stats)
}

/// `slick_files_build` that stops when `cancel` is set, from any thread. The walker checks it once
/// per folder; a stopped build returns `SLICK_STATUS_CANCELLED`, stores NULL in `*out` and leaves
/// `*stats` alone. A NULL `cancel` never stops.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_build_cancellable(
    config: *const SlickFilesConfig,
    strings: *const u8,
    strings_len: usize,
    cancel: *const SlickFilesCancel,
    out: *mut *mut SlickFiles,
    stats: *mut SlickFilesWalkStats,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        *slot = std::ptr::null_mut();
        let config = self::config(handle(config)?, bytes(strings, strings_len)?)?;
        let (inner, walked) = FileIndex::build_cancellable(config, stop(cancel)?).map_err(cancelled)?;
        put(stats, walk_stats(&walked))?;
        *slot = Box::into_raw(Box::new(SlickFiles { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Opens the index file at `path` when it was saved for the same roots and rules, and otherwise
/// builds a new index. Stores the index in `*out` and what happened in `*info` when it is not
/// NULL. Reads or walks the disk: call it off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_open_or_build(
    path: *const u8,
    path_len: usize,
    config: *const SlickFilesConfig,
    strings: *const u8,
    strings_len: usize,
    out: *mut *mut SlickFiles,
    info: *mut SlickFilesOpenInfo,
) -> i32 {
    slick_files_open_or_build_cancellable(
        path,
        path_len,
        config,
        strings,
        strings_len,
        std::ptr::null(),
        out,
        info,
    )
}

/// `slick_files_open_or_build` whose build stops when `cancel` is set. Opening the file is not
/// interrupted. A stopped build returns `SLICK_STATUS_CANCELLED`, stores NULL in `*out` and leaves
/// `*info` alone. A NULL `cancel` never stops.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn slick_files_open_or_build_cancellable(
    path: *const u8,
    path_len: usize,
    config: *const SlickFilesConfig,
    strings: *const u8,
    strings_len: usize,
    cancel: *const SlickFilesCancel,
    out: *mut *mut SlickFiles,
    info: *mut SlickFilesOpenInfo,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        *slot = std::ptr::null_mut();
        let file = file_path(path, path_len)?;
        let config = self::config(handle(config)?, bytes(strings, strings_len)?)?;
        let stop = stop(cancel)?;
        let mut result = SlickFilesOpenInfo::default();
        let inner = match FileIndex::open(file, config.clone()) {
            Ok((inner, meta)) => {
                result.opened = 1;
                result.event_id = meta.event_id;
                result.saved_at = meta.saved_at;
                inner
            }
            Err(e) => {
                result.load_error = match e {
                    LoadError::Io(e) if e.kind() == std::io::ErrorKind::NotFound => SLICK_FILES_LOAD_MISSING,
                    LoadError::Io(_) => SLICK_FILES_LOAD_IO,
                    LoadError::Corrupt(_) => SLICK_FILES_LOAD_CORRUPT,
                    LoadError::Version(_) => SLICK_FILES_LOAD_VERSION,
                    LoadError::Mismatch => SLICK_FILES_LOAD_MISMATCH,
                };
                let (inner, walked) = FileIndex::build_cancellable(config, stop).map_err(cancelled)?;
                result.walk = walk_stats(&walked);
                inner
            }
        };
        result.entries = inner.snapshot().len() as u64;
        put(info, result)?;
        *slot = Box::into_raw(Box::new(SlickFiles { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Builds an index of about `entries` synthetic entries below the absolute path `root` in memory,
/// deterministic for each `seed`, and stores it in `*out`. Nothing is read from or written to the
/// disk until an event or a rebuild asks for it. For tests and benchmarks.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_synthetic(
    root: *const u8,
    root_len: usize,
    entries: u32,
    seed: u64,
    out: *mut *mut SlickFiles,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let root = bytes(root, root_len)?;
        if root.first() != Some(&b'/') || root.contains(&0) {
            return Err(SlickStatus::InvalidArgument);
        }
        let snap = crate::synthetic::tree(entries.max(1) as usize, root, seed);
        let config = Config::new(vec![path_of(root)], Rules::everything());
        let inner = FileIndex::from_snapshot(config, snap);
        *slot = Box::into_raw(Box::new(SlickFiles { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees an index. NULL is allowed. Snapshots and sessions that hold its data keep it alive.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_free(index: *mut SlickFiles) -> i32 {
    guard(|| {
        if !index.is_null() {
            // SAFETY: a non-NULL index came from `slick_files_build` or `slick_files_open_or_build`
            // and is freed once.
            drop(unsafe { Box::from_raw(index) });
        }
        SlickStatus::Ok as i32
    })
}

/// Returns the number of live entries in the index's current snapshot.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_count(index: *const SlickFiles) -> i32 {
    guard_result(|| Ok(i32::try_from(self::index(index)?.snapshot().len()).unwrap_or(i32::MAX)))
}

/// Applies one batch of FSEvents events: `count` events whose paths are spans of `paths`. Rescans
/// only the folders they touch and publishes a new snapshot when anything changed. Searches keep
/// running meanwhile. Fills `*stats` when it is not NULL. Reads the disk: call it off the main
/// thread, from one queue.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_apply(
    index: *const SlickFiles,
    events: *const SlickFilesEvent,
    count: usize,
    paths: *const u8,
    paths_len: usize,
    stats: *mut SlickFilesUpdateStats,
) -> i32 {
    slick_files_apply_cancellable(index, events, count, paths, paths_len, std::ptr::null(), stats)
}

/// `slick_files_apply` that stops when `cancel` is set. Subtree rescans and the full walk after
/// lost history check it once per folder. A stopped batch returns `SLICK_STATUS_CANCELLED`, changes
/// nothing and leaves `*stats` alone; apply the events again, or rebuild, to catch up. A NULL
/// `cancel` never stops.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_apply_cancellable(
    index: *const SlickFiles,
    events: *const SlickFilesEvent,
    count: usize,
    paths: *const u8,
    paths_len: usize,
    cancel: *const SlickFilesCancel,
    stats: *mut SlickFilesUpdateStats,
) -> i32 {
    guard_result(|| {
        let stop = stop(cancel)?;
        let ix = self::index(index)?;
        let list = slice(events, count)?;
        let paths = bytes(paths, paths_len)?;
        let events = list
            .iter()
            .map(|e| {
                Ok(Event {
                    path: span(paths, e.path_start, e.path_len)?.to_vec(),
                    flags: e.flags,
                })
            })
            .collect::<Result<Vec<Event>, SlickStatus>>()?;
        let done = ix.apply_cancellable(&events, stop).map_err(cancelled)?;
        put(stats, update_stats(&done))?;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Walks every root again and publishes the result. Fills `*stats` when it is not NULL.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_rebuild(index: *const SlickFiles, stats: *mut SlickFilesWalkStats) -> i32 {
    slick_files_rebuild_cancellable(index, std::ptr::null(), stats)
}

/// `slick_files_rebuild` that stops when `cancel` is set. A stopped rebuild returns
/// `SLICK_STATUS_CANCELLED`, keeps the snapshot the index had and leaves `*stats` alone. A NULL
/// `cancel` never stops.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_rebuild_cancellable(
    index: *const SlickFiles,
    cancel: *const SlickFilesCancel,
    stats: *mut SlickFilesWalkStats,
) -> i32 {
    guard_result(|| {
        let walked = self::index(index)?
            .rebuild_cancellable(stop(cancel)?)
            .map_err(cancelled)?;
        put(stats, walk_stats(&walked))?;
        Ok(SlickStatus::Ok as i32)
    })
}

// ---- cancel flags

/// Creates a cancel flag that is not set and stores it in `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_new(out: *mut *mut SlickFilesCancel) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        *slot = Box::into_raw(Box::new(SlickFilesCancel { inner: Cancel::new() }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees a cancel flag. NULL is allowed. Call it only after every call that uses the flag has
/// returned.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_free(cancel: *mut SlickFilesCancel) -> i32 {
    guard(|| {
        if !cancel.is_null() {
            // SAFETY: a non-NULL flag came from `slick_files_cancel_new`, is freed once, and no
            // call that uses it is still running, as the caller guarantees.
            drop(unsafe { Box::from_raw(cancel) });
        }
        SlickStatus::Ok as i32
    })
}

/// Sets the flag. Every walk that checks it stops at its next folder. Safe from any thread, also
/// while a walk runs.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_set(cancel: *const SlickFilesCancel) -> i32 {
    guard_result(|| {
        handle(cancel)?.inner.cancel();
        Ok(SlickStatus::Ok as i32)
    })
}

/// Clears the flag, so it can stop another walk.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_reset(cancel: *const SlickFilesCancel) -> i32 {
    guard_result(|| {
        handle(cancel)?.inner.reset();
        Ok(SlickStatus::Ok as i32)
    })
}

/// Returns 1 when the flag is set, else 0.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_is_set(cancel: *const SlickFilesCancel) -> i32 {
    guard_result(|| Ok(i32::from(handle(cancel)?.inner.is_cancelled())))
}

/// Lets `folders` more folder checks pass and then sets the flag, so a test stops a walk at a
/// known point without racing a second thread. 0 sets it at once. For tests.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_cancel_after(cancel: *const SlickFilesCancel, folders: u64) -> i32 {
    guard_result(|| {
        handle(cancel)?.inner.cancel_after(folders);
        Ok(SlickStatus::Ok as i32)
    })
}

// ---- folders outside the index

/// Lists the folder at the absolute `path` from disk, with the rules of `config` (spans into
/// `strings`; its roots are not used), sorted by name, for browsing a folder the index does not
/// hold. Writes one item per child into `items` and the names, back to back, into `names`, and
/// returns the number of items. Always fills `*info`. Returns `SLICK_STATUS_BUFFER_TOO_SMALL` when
/// either buffer is short; `info` then gives the room both need, so call it with capacities 0 to
/// measure. Returns `SLICK_STATUS_IO` when the folder cannot be listed, with the reason in
/// `info.problem`. A symbolic link at the end of `path` is not followed.
///
/// Reads the disk: call it off the main thread. Reading a folder macOS guards, such as Desktop or
/// Downloads, can raise a permission prompt, so list only folders the user chose to browse.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn slick_files_list_folder(
    path: *const u8,
    path_len: usize,
    config: *const SlickFilesConfig,
    strings: *const u8,
    strings_len: usize,
    items: *mut SlickFilesListItem,
    items_cap: usize,
    names: *mut u8,
    names_cap: usize,
    info: *mut SlickFilesListInfo,
) -> i32 {
    guard_result(|| {
        let report = handle_mut(info)?;
        *report = SlickFilesListInfo::default();
        let dir = file_path(path, path_len)?;
        if !dir.is_absolute() {
            return Err(SlickStatus::InvalidArgument);
        }
        let rules = self::config(handle(config)?, bytes(strings, strings_len)?)?.rules;
        let items = out(items, items_cap)?;
        let names = out(names, names_cap)?;
        let listing = match slick_files::walk::list_folder_checked(dir, &rules) {
            Ok(l) => l,
            Err(e) => {
                report.problem = match e.kind() {
                    std::io::ErrorKind::NotFound => SLICK_FILES_LIST_MISSING,
                    std::io::ErrorKind::NotADirectory => SLICK_FILES_LIST_NOT_FOLDER,
                    std::io::ErrorKind::PermissionDenied => SLICK_FILES_LIST_DENIED,
                    _ => SLICK_FILES_LIST_FAILED,
                };
                return Err(SlickStatus::Io);
            }
        };
        let name_bytes: usize = listing.entries.iter().map(|e| e.name.len()).sum();
        report.items = listing.entries.len() as u64;
        report.name_bytes = name_bytes as u64;
        report.complete = u8::from(listing.complete);
        if listing.entries.len() > items.len() || name_bytes > names.len() {
            return Err(SlickStatus::BufferTooSmall);
        }
        let count = i32::try_from(listing.entries.len()).map_err(|_| SlickStatus::InvalidArgument)?;
        let mut at = 0usize;
        for (slot, e) in items.iter_mut().zip(&listing.entries) {
            names[at..at + e.name.len()].copy_from_slice(&e.name);
            *slot = SlickFilesListItem {
                size: e.size.unwrap_or(u64::MAX),
                name_start: u32::try_from(at).map_err(|_| SlickStatus::InvalidArgument)?,
                name_len: u32::try_from(e.name.len()).map_err(|_| SlickStatus::InvalidArgument)?,
                mtime: e.mtime,
                flags: e.flags,
                reserved: [0; 3],
            };
            at += e.name.len();
        }
        Ok(count)
    })
}

/// Writes the current snapshot to `path` atomically, with mode 0600. `event_id` is the FSEvents id
/// the snapshot is current to. Returns `SLICK_STATUS_IO` when the file cannot be written.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_save(index: *const SlickFiles, path: *const u8, path_len: usize, event_id: u64) -> i32 {
    guard_result(|| {
        let ix = self::index(index)?;
        ix.save(file_path(path, path_len)?, event_id)
            .map_err(|_| SlickStatus::Io)?;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Stores the index's current snapshot in `*out`. Cheap: one reference count.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot(index: *const SlickFiles, out: *mut *mut SlickFilesSnapshot) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let inner = self::index(index)?.snapshot();
        *slot = Box::into_raw(Box::new(SlickFilesSnapshot { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

// ---- snapshots

/// Frees a snapshot. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot_free(snapshot: *mut SlickFilesSnapshot) -> i32 {
    guard(|| {
        if !snapshot.is_null() {
            // SAFETY: a non-NULL snapshot came from this module and is freed once.
            drop(unsafe { Box::from_raw(snapshot) });
        }
        SlickStatus::Ok as i32
    })
}

/// Writes facts about the snapshot into `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot_info(snapshot: *const SlickFilesSnapshot, out: *mut SlickFilesInfo) -> i32 {
    guard_result(|| {
        let s = handle(snapshot)?;
        *handle_mut(out)? = snapshot_info(&s.inner);
        Ok(SlickStatus::Ok as i32)
    })
}

/// Copies the absolute path of entry `id` into `out` and returns its byte length. With `cap` 0
/// nothing is written and the length comes back. Returns `SLICK_STATUS_BUFFER_TOO_SMALL` when the
/// path does not fit and `SLICK_STATUS_INVALID_ARGUMENT` for an id the snapshot does not hold.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot_path(
    snapshot: *const SlickFilesSnapshot,
    id: u32,
    out: *mut u8,
    cap: usize,
) -> i32 {
    guard_result(|| write_path(&handle(snapshot)?.inner, id, out, cap))
}

/// Writes facts about entry `id` into `*out`. Returns `SLICK_STATUS_INVALID_ARGUMENT` for an id the
/// snapshot does not hold.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot_entry(
    snapshot: *const SlickFilesSnapshot,
    id: u32,
    out: *mut SlickFileEntry,
) -> i32 {
    guard_result(|| write_entry(&handle(snapshot)?.inner, id, out))
}

/// Finds the entry for an absolute path. Returns 1 and stores the id in `*out_id` when the
/// snapshot holds the whole path, else 0.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_snapshot_lookup(
    snapshot: *const SlickFilesSnapshot,
    path: *const u8,
    len: usize,
    out_id: *mut u32,
) -> i32 {
    guard_result(|| {
        let s = handle(snapshot)?;
        let id = handle_mut(out_id)?;
        *id = SLICK_FILES_NONE;
        match s.inner.lookup(bytes(path, len)?) {
            Some((found, true)) => {
                *id = found;
                Ok(1)
            }
            _ => Ok(0),
        }
    })
}

// ---- sessions

/// Creates a search session and stores it in `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_new(out: *mut *mut SlickFilesSession) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let width = std::thread::available_parallelism().map_or(4, |n| n.get());
        *slot = Box::into_raw(Box::new(SlickFilesSession {
            searcher: Searcher::new(),
            hits: Vec::with_capacity(64),
            options: SearchOptions::default(),
            query: String::with_capacity(256),
            ranges: Vec::with_capacity(16),
            gcd: Gcd { width },
        }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees a session. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_free(session: *mut SlickFilesSession) -> i32 {
    guard(|| {
        if !session.is_null() {
            // SAFETY: a non-NULL session came from `slick_files_session_new` and is freed once.
            drop(unsafe { Box::from_raw(session) });
        }
        SlickStatus::Ok as i32
    })
}

/// Forgets earlier queries, so the next search scans everything. Call it when the panel opens.
/// The hits and the snapshot of the last search stay readable.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_reset(session: *mut SlickFilesSession) -> i32 {
    guard_result(|| {
        handle_mut(session)?.searcher.reset();
        Ok(SlickStatus::Ok as i32)
    })
}

/// Sets the home folder that a leading `~` in a folder query expands to. Empty turns `~` off.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_set_home(session: *mut SlickFilesSession, home: *const u8, len: usize) -> i32 {
    guard_result(|| {
        let s = handle_mut(session)?;
        let home = bytes(home, len)?;
        s.options.home = (!home.is_empty()).then(|| home.to_vec());
        s.searcher.reset();
        Ok(SlickStatus::Ok as i32)
    })
}

/// Searches the index's current snapshot for `query` (UTF-8) and writes the best hits into `out`,
/// best first, at most `cap`. Returns the number written. When the query only grew since the last
/// search on the same snapshot with the same filters, only the previous matches are scored again.
/// Text that starts with `/` or `~` lists a folder instead. The parts run in parallel unless
/// `options.flags` has `SLICK_FILES_SEARCH_SERIAL`. Allocates nothing once the session is warm.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_search(
    index: *const SlickFiles,
    session: *mut SlickFilesSession,
    query: *const u8,
    len: usize,
    options: *const SlickFilesOptions,
    out: *mut SlickFileHit,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let ix = self::index(index)?;
        let s = handle_mut(session)?;
        let o = handle(options)?;
        let dst = self::out(out, cap)?;
        let q = text(query, len)?;
        let opts = &mut s.options;
        opts.limit = dst.len();
        opts.within = (o.within != SLICK_FILES_NONE).then_some(o.within);
        opts.kinds = match o.kinds {
            SLICK_FILES_KINDS_ALL => Kinds::All,
            SLICK_FILES_KINDS_FILES => Kinds::Files,
            SLICK_FILES_KINDS_FOLDERS => Kinds::Folders,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        opts.prefer = match o.prefer {
            SLICK_FILES_PREFER_NEITHER => Prefer::Neither,
            SLICK_FILES_PREFER_FILES => Prefer::Files,
            SLICK_FILES_PREFER_FOLDERS => Prefer::Folders,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        opts.browse_sort = match o.browse_sort {
            SLICK_FILES_SORT_NAME => BrowseSort::Name,
            SLICK_FILES_SORT_MODIFIED => BrowseSort::Modified,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        opts.include_hidden = o.flags & SLICK_FILES_SEARCH_HIDDEN != 0;
        opts.typo = o.flags & SLICK_FILES_SEARCH_NO_TYPO == 0;
        opts.now = o.now;
        s.query.clear();
        s.query.push_str(q);
        let snap = ix.snapshot();
        let par: &dyn ParallelFor = if o.flags & SLICK_FILES_SEARCH_SERIAL != 0 {
            &Serial
        } else {
            &s.gcd
        };
        s.searcher.search(&snap, q, &s.options, par, &mut s.hits);
        let view = s.searcher.snapshot().ok_or(SlickStatus::InvalidArgument)?;
        let n = s.hits.len().min(dst.len());
        for (d, h) in dst.iter_mut().zip(&s.hits) {
            let (flags, depth) = view.entry(h.id).map_or((0, 0), |e| (e.flags, e.depth));
            *d = SlickFileHit {
                id: h.id,
                rank: h.rank,
                how: h.how as u8,
                tier: h.tier(),
                flags,
                depth,
            };
        }
        Ok(n as i32)
    })
}

/// Writes the UTF-16 highlight ranges of `hit`'s name for the session's last search into `out`
/// and returns how many were written. `hit` must come from that search. Call it for visible rows
/// only.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_ranges(
    session: *mut SlickFilesSession,
    hit: *const SlickFileHit,
    out: *mut SlickRange,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let s = handle_mut(session)?;
        let h = handle(hit)?;
        let hit = FileHit {
            id: h.id,
            rank: h.rank,
            how: how(h.how)?,
        };
        let SlickFilesSession {
            searcher,
            options,
            query,
            ranges,
            ..
        } = s;
        searcher.highlight(&hit, query, options, ranges);
        write_ranges(ranges, out, cap)
    })
}

/// Copies the absolute path of entry `id` in the session's last search into `out`. See
/// `slick_files_snapshot_path`. Returns `SLICK_STATUS_INVALID_ARGUMENT` before the first search.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_path(
    session: *const SlickFilesSession,
    id: u32,
    out: *mut u8,
    cap: usize,
) -> i32 {
    guard_result(|| write_path(session_snapshot(handle(session)?)?, id, out, cap))
}

/// Writes facts about entry `id` in the session's last search into `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_entry(
    session: *const SlickFilesSession,
    id: u32,
    out: *mut SlickFileEntry,
) -> i32 {
    guard_result(|| write_entry(session_snapshot(handle(session)?)?, id, out))
}

/// Stores the snapshot of the session's last search in `*out`, so its hits stay resolvable after
/// the session moves on. Returns `SLICK_STATUS_INVALID_ARGUMENT` before the first search.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_snapshot(
    session: *const SlickFilesSession,
    out: *mut *mut SlickFilesSnapshot,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let inner = Arc::clone(session_snapshot(handle(session)?)?);
        *slot = Box::into_raw(Box::new(SlickFilesSnapshot { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Writes what the session's last search did into `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_files_session_stats(session: *const SlickFilesSession, out: *mut SlickFilesSearchStats) -> i32 {
    guard_result(|| {
        let st = handle(session)?.searcher.stats();
        *handle_mut(out)? = SlickFilesSearchStats {
            scanned: st.scanned as u64,
            prefix_only: st.prefix_only as u8,
            narrowed: st.narrowed as u8,
            typo_ran: st.typo_ran as u8,
            not_indexed: st.not_indexed as u8,
            reserved: 0,
        };
        Ok(SlickStatus::Ok as i32)
    })
}
