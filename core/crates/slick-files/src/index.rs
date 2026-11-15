//! The shared index handle: one published snapshot for readers, one writer.
//!
//! Readers call [`FileIndex::snapshot`], which clones an `Arc` under a read lock. The write lock is
//! only ever held for the writer's pointer swap, so a reader waits nanoseconds at most, and readers
//! never wait for each other.
//! The writer does all of its disk access and copying on a private copy of the snapshot that
//! shares every unchanged chunk with the published one, then swaps the pointer.

use crate::persist::{self, FileMeta, LoadError};
use crate::rules::{Compiled, Rules};
use crate::store::{Builder, EntryId, Snapshot, flags};
use crate::update::{self, Event, UpdateStats};
use crate::walk::{self, Method, Scratch, WalkStats};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::Instant;

/// What to index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// Absolute folders. Nested roots are dropped; symbolic links in a root path are resolved
    /// once, when the index is built.
    pub roots: Vec<PathBuf>,
    pub rules: Rules,
    /// Walker threads for a full build.
    pub threads: usize,
}

impl Config {
    pub fn new(roots: Vec<PathBuf>, rules: Rules) -> Config {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8);
        Config { roots, rules, threads }
    }

    /// The roots as the index stores them: resolved, without nesting, in the given order.
    pub(crate) fn resolved_roots(&self) -> Vec<Vec<u8>> {
        let mut out: Vec<Vec<u8>> = Vec::new();
        for r in &self.roots {
            let p = std::fs::canonicalize(r).unwrap_or_else(|_| r.clone());
            let b = trim(p.as_os_str().as_bytes()).to_vec();
            if !out.contains(&b) {
                out.push(b);
            }
        }
        let all = out.clone();
        out.retain(|p| {
            !all.iter()
                .any(|q| q != p && p.starts_with(q) && (p.get(q.len()) == Some(&b'/') || q == b"/"))
        });
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

/// Walks every root into a fresh snapshot.
fn build_snapshot(config: &Config, rules: &Compiled) -> (Snapshot, Vec<u64>, WalkStats) {
    let began = Instant::now();
    let mut b = Builder::new();
    let mut devs = Vec::new();
    let mut stats = WalkStats::default();
    for root in config.resolved_roots() {
        match walk::walk(&root, 0, rules, config.threads, Method::Bulk, None) {
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
    (s, devs, stats)
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
        let rules = config.rules.compile();
        let (snap, devs, stats) = build_snapshot(&config, &rules);
        (FileIndex::with(config, rules, snap, devs), stats)
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
        let began = Instant::now();
        let mut stats = UpdateStats::default();
        let mut guard = lock(&self.writer);
        let w = &mut *guard;
        let t = update::targets(&w.work, &w.rules, events, &mut stats);
        if t.full {
            let (snap, devs, _) = build_snapshot(&w.config, &w.rules);
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
                update::rescan(&mut w.work, id, deep, &w.rules, &root_dev, &mut w.scratch, &mut stats);
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
        stats
    }

    /// Walks every root again and publishes the result.
    pub fn rebuild(&self) -> WalkStats {
        let mut guard = lock(&self.writer);
        let w = &mut *guard;
        let (snap, devs, stats) = build_snapshot(&w.config, &w.rules);
        w.work = snap;
        w.devs = devs;
        self.publish(w);
        stats
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
