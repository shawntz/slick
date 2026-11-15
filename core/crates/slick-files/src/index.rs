//! The shared index handle: one published snapshot for readers, one writer.
//!
//! Readers call [`FileIndex::snapshot`], which clones an `Arc` under a read lock. The write lock is
//! only ever held for the writer's pointer swap, so a reader waits nanoseconds at most, and readers
//! never wait for each other.
//! The writer does all of its disk access and copying on a private copy of the snapshot that
//! shares every unchanged chunk with the published one, then swaps the pointer.

use crate::cancel::{self, Cancel, Cancelled};
use crate::persist::{self, FileMeta, LoadError};
use crate::rules::{Compiled, Rules};
use crate::store::{Builder, EntryId, Snapshot, flags};
use crate::update::{self, Event, UpdateStats};
use crate::walk::{self, ListError, Method, Scratch, WalkStats};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::Instant;

/// What to index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// Absolute folders. Nested roots are dropped, except as `keep_unreached_roots` says; symbolic
    /// links in a root path are resolved once, when the index is built.
    pub roots: Vec<PathBuf>,
    pub rules: Rules,
    /// Walker threads for a full build.
    pub threads: usize,
    /// Keep a root nested in another when the walk of the outer root never enters it, because a
    /// skipped path, a skipped or hidden name, or a package lies on the way, or the root is itself
    /// skipped. iCloud Drive inside a skipped Library folder is the case this is for. Off by
    /// default: every nested root is dropped.
    pub keep_unreached_roots: bool,
}

impl Config {
    pub fn new(roots: Vec<PathBuf>, rules: Rules) -> Config {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8);
        Config {
            roots,
            rules,
            threads,
            keep_unreached_roots: false,
        }
    }

    /// The roots as the index stores them: resolved, without nesting, in the given order. With
    /// `keep_unreached_roots`, a nested root stays when no walk of an outer root would enter it.
    pub(crate) fn resolved_roots(&self) -> Vec<Vec<u8>> {
        let mut out: Vec<Vec<u8>> = Vec::new();
        for r in &self.roots {
            let p = std::fs::canonicalize(r).unwrap_or_else(|_| r.clone());
            let b = trim(p.as_os_str().as_bytes()).to_vec();
            if !out.contains(&b) {
                out.push(b);
            }
        }
        let rules = self.keep_unreached_roots.then(|| self.rules.compile());
        // Outer roots are decided first, and only a root that stays can cover a nested one: a
        // package root that is dropped does not cover its contents.
        let mut order: Vec<usize> = (0..out.len()).collect();
        order.sort_by_key(|&i| out[i].len());
        let mut keep = vec![false; out.len()];
        for &i in &order {
            let p = &out[i];
            keep[i] = !order.iter().any(|&j| {
                let q = &out[j];
                keep[j]
                    && j != i
                    && p.starts_with(q)
                    && (p.get(q.len()) == Some(&b'/') || q.as_slice() == b"/")
                    && rules.as_ref().is_none_or(|r| r.enters(q, p))
            });
        }
        let mut kept = keep.iter();
        out.retain(|_| kept.next().copied().unwrap_or(false));
        out
    }

    /// A hash of the roots and rules, stored in index files so a file built for other settings
    /// is not reused.
    pub(crate) fn fingerprint(&self) -> u64 {
        let mut h = crate::hash::Fnv::new();
        h.write(&self.rules.fingerprint().to_le_bytes());
        for r in self.resolved_roots() {
            h.write(&(r.len() as u64).to_le_bytes());
            h.write(&r);
        }
        h.finish()
    }
}

fn trim(p: &[u8]) -> &[u8] {
    let mut end = p.len();
    while end > 1 && p[end - 1] == b'/' {
        end -= 1;
    }
    &p[..end]
}

struct Writer {
    config: Config,
    rules: Compiled,
    work: Snapshot,
    /// Device of each root, in root order. 0 when unknown.
    devs: Vec<u64>,
    generation: u64,
    scratch: Scratch,
}

/// A file index that many threads search while one writer keeps it current.
pub struct FileIndex {
    published: RwLock<Arc<Snapshot>>,
    writer: Mutex<Writer>,
}

/// Share of dead slots above which the writer compacts.
const COMPACT_RATIO: f64 = 0.25;
const COMPACT_MIN_DEAD: usize = 4_096;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Walks every root into a fresh snapshot, unless `stop` is set first.
fn build_snapshot(
    config: &Config,
    rules: &Compiled,
    stop: &Cancel,
) -> Result<(Snapshot, Vec<u64>, WalkStats), Cancelled> {
    let began = Instant::now();
    let mut b = Builder::new();
    let mut devs = Vec::new();
    let mut stats = WalkStats::default();
    for root in config.resolved_roots() {
        match walk::walk(&root, 0, rules, config.threads, Method::Bulk, None, stop) {
            Err(ListError::Cancelled) => return Err(Cancelled),
            Ok(tree) => {
                let id = b.root(&root, tree.meta.mtime);
                walk::graft(&mut b.snap, id, &tree);
                devs.push(tree.meta.dev);
                stats.dirs += tree.stats.dirs;
                stats.entries += tree.stats.entries;
                stats.unreadable += tree.stats.unreadable;
            }
            Err(_) => {
                let id = b.root(&root, 0);
                b.snap.add_flags(id, flags::UNREADABLE);
                devs.push(0);
                stats.unreadable += 1;
            }
        }
    }
    let mut s = b.finish();
    s.rules_hash = config.fingerprint();
    stats.elapsed = began.elapsed();
    Ok((s, devs, stats))
}

/// The result of a walk that no one can cancel.
fn uncancelled<T>(r: Result<T, Cancelled>) -> T {
    match r {
        Ok(v) => v,
        Err(Cancelled) => unreachable!("a walk without a cancel flag was cancelled"),
    }
}

fn root_devs(config: &Config) -> Vec<u64> {
    config
        .resolved_roots()
        .iter()
        .map(|r| walk::open_dir(r).map_or(0, |(_, m)| m.dev))
        .collect()
}

impl FileIndex {
    /// Walks every root and returns the index with what the walk saw.
    pub fn build(config: Config) -> (FileIndex, WalkStats) {
        uncancelled(FileIndex::build_cancellable(config, &cancel::NEVER))
    }

    /// [`FileIndex::build`] that stops early when `stop` is set, from any thread. The walker
    /// checks `stop` once per folder.
    pub fn build_cancellable(config: Config, stop: &Cancel) -> Result<(FileIndex, WalkStats), Cancelled> {
        let rules = config.rules.compile();
        let (snap, devs, stats) = build_snapshot(&config, &rules, stop)?;
        Ok((FileIndex::with(config, rules, snap, devs), stats))
    }

    /// An index over a snapshot made elsewhere, such as a [`Builder`] fed with synthetic entries.
    /// Updates rescan the snapshot's roots on disk.
    pub fn from_snapshot(config: Config, mut snap: Snapshot) -> FileIndex {
        let rules = config.rules.compile();
        snap.rules_hash = config.fingerprint();
        let devs = root_devs(&config);
        FileIndex::with(config, rules, snap, devs)
    }

    fn with(config: Config, rules: Compiled, mut snap: Snapshot, devs: Vec<u64>) -> FileIndex {
        snap.generation = 1;
        FileIndex {
            published: RwLock::new(Arc::new(snap.clone())),
            writer: Mutex::new(Writer {
                config,
                rules,
                work: snap,
                devs,
                generation: 1,
                scratch: Scratch::default(),
            }),
        }
    }

    /// Opens an index file written by [`FileIndex::save`] for the same roots and rules. The
    /// columns stay in the mapped file until the writer changes them. A damaged file, a file from
    /// another format version, or a file for other settings is refused; build a new index then.
    pub fn open(path: &Path, config: Config) -> Result<(FileIndex, FileMeta), LoadError> {
        let (snap, meta) = persist::read(path, config.fingerprint())?;
        let rules = config.rules.compile();
        let devs = root_devs(&config);
        let idx = FileIndex::with(config, rules, snap, devs);
        Ok((idx, meta))
    }

    /// Opens the file at `path`, or builds a new index when it is missing or refused. Returns the
    /// load error when there was one.
    pub fn open_or_build(path: &Path, config: Config) -> (FileIndex, Option<FileMeta>, Option<LoadError>) {
        match FileIndex::open(path, config.clone()) {
            Ok((i, m)) => (i, Some(m), None),
            Err(e) => (FileIndex::build(config).0, None, Some(e)),
        }
    }

    /// The current snapshot. Cheap: one `Arc` clone.
    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.published.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn publish(&self, w: &mut Writer) {
        w.generation += 1;
        w.work.generation = w.generation;
        let next = Arc::new(w.work.clone());
        let old = {
            let mut guard = self.published.write().unwrap_or_else(|e| e.into_inner());
            std::mem::replace(&mut *guard, next)
        };
        // The old snapshot is freed outside the lock, here or by its last reader.
        drop(old);
    }

    /// Applies one batch of FSEvents events and publishes the result. Blocks other writers, never
    /// readers.
    pub fn apply(&self, events: &[Event]) -> UpdateStats {
        uncancelled(self.apply_cancellable(events, &cancel::NEVER))
    }

    /// [`FileIndex::apply`] that stops early when `stop` is set. A stopped batch changes nothing:
    /// the index keeps the snapshot it had, and the events are not applied. Rescans of whole
    /// subtrees and the full walk after lost history check `stop` once per folder.
    pub fn apply_cancellable(&self, events: &[Event], stop: &Cancel) -> Result<UpdateStats, Cancelled> {
        let began = Instant::now();
        let mut stats = UpdateStats::default();
        let mut guard = lock(&self.writer);
        let w = &mut *guard;
        let t = update::targets(&w.work, &w.rules, events, &mut stats);
        if t.full {
            let (snap, devs, _) = build_snapshot(&w.config, &w.rules, stop)?;
            w.work = snap;
            w.devs = devs;
            stats.full = true;
        } else {
            let roots: Vec<EntryId> = w.work.roots().map(|(id, _)| id).collect();
            let devs = w.devs.clone();
            let root_dev = |s: &Snapshot, id: EntryId| -> u64 {
                s.root_of(id)
                    .and_then(|r| roots.iter().position(|&x| x == r.id))
                    .and_then(|i| devs.get(i).copied())
                    .unwrap_or(0)
            };
            for &(id, deep) in &t.list {
                let stopped = update::rescan(
                    &mut w.work,
                    id,
                    deep,
                    &w.rules,
                    &root_dev,
                    &mut w.scratch,
                    &mut stats,
                    stop,
                );
                if stopped {
                    // Drop the half-applied batch: the next writer starts from what readers see.
                    w.work = (*self.snapshot()).clone();
                    return Err(Cancelled);
                }
            }
        }
        let dead = w.work.slots() - w.work.len();
        if w.work.dead_ratio() > COMPACT_RATIO && dead > COMPACT_MIN_DEAD {
            w.work = w.work.compacted();
        }
        if stats.full || stats.added + stats.removed + stats.changed > 0 {
            self.publish(w);
            stats.published = true;
        }
        stats.elapsed = began.elapsed();
        Ok(stats)
    }

    /// Walks every root again and publishes the result.
    pub fn rebuild(&self) -> WalkStats {
        uncancelled(self.rebuild_cancellable(&cancel::NEVER))
    }

    /// [`FileIndex::rebuild`] that stops early when `stop` is set. A stopped rebuild keeps the
    /// snapshot the index had.
    pub fn rebuild_cancellable(&self, stop: &Cancel) -> Result<WalkStats, Cancelled> {
        let mut guard = lock(&self.writer);
        let w = &mut *guard;
        let (snap, devs, stats) = build_snapshot(&w.config, &w.rules, stop)?;
        w.work = snap;
        w.devs = devs;
        self.publish(w);
        Ok(stats)
    }

    /// Writes the published snapshot to `path` atomically. `event_id` is the FSEvents id the
    /// snapshot is current to; [`FileIndex::open`] hands it back so the stream can resume there.
    pub fn save(&self, path: &Path, event_id: u64) -> io::Result<()> {
        let snap = self.snapshot();
        persist::write(path, &snap, event_id)
    }

    /// The configuration the index was made with.
    pub fn config(&self) -> Config {
        lock(&self.writer).config.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roots_below_a_skip_stay_only_when_asked() {
        let mut rules = Rules::recommended(Some(Path::new("/tmp/vf-home")));
        rules.skip_names.push("Skipped".into());
        let roots = |keep: bool| {
            let mut c = Config::new(
                vec![
                    PathBuf::from("/tmp/vf-home"),
                    PathBuf::from("/tmp/vf-home/Library/Mobile Documents"),
                    PathBuf::from("/tmp/vf-home/Library"),
                    PathBuf::from("/tmp/vf-home/docs"),
                    PathBuf::from("/tmp/vf-home/docs/Skipped/inner"),
                    PathBuf::from("/tmp/vf-home/.dot/inner"),
                    PathBuf::from("/tmp/vf-home/Editor.app/Contents"),
                    PathBuf::from("/tmp/vf-home/Editor.app"),
                ],
                rules.clone(),
            );
            c.keep_unreached_roots = keep;
            c.resolved_roots()
                .iter()
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(roots(false), vec!["/tmp/vf-home"]);
        assert_eq!(
            roots(true),
            vec![
                "/tmp/vf-home",
                "/tmp/vf-home/Library",
                "/tmp/vf-home/docs/Skipped/inner",
                "/tmp/vf-home/.dot/inner",
                "/tmp/vf-home/Editor.app/Contents",
            ],
            "Library is skipped and holds Mobile Documents, which is dropped below the Library root; \
             docs is walked; a package is one entry of the outer root but its contents are not"
        );
    }

    #[test]
    fn nested_and_repeated_roots_collapse() {
        let c = Config::new(
            vec![
                PathBuf::from("/tmp/a/"),
                PathBuf::from("/tmp/a/b"),
                PathBuf::from("/tmp/a"),
                PathBuf::from("/tmp/ab"),
            ],
            Rules::everything(),
        );
        let r = c.resolved_roots();
        assert!(r.iter().all(|p| !p.ends_with(b"/")));
        assert_eq!(
            r.len(),
            2,
            "{:?}",
            r.iter()
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .collect::<Vec<_>>()
        );
    }
}
