//! Persistence: the append-only event log and the snapshots, written on the store's own thread.
//!
//! One engine owns a data directory at a time (see `recover`). Files, all created with mode 0600
//! under the data directory:
//! - `events.log`: 32-byte records with a CRC each (see `slick_predict::log`). Appends are one
//!   write per batch. A crash can leave a torn last record. Recovery reads only the records after
//!   the snapshot, truncates the log at the first one that fails its CRC or does not fit the
//!   state, and goes on. After a compaction the file starts with a `Base` record that numbers the
//!   records after it.
//! - `snapshot.bin` and `snapshot.prev.bin`: the newest and the previous versioned learning state,
//!   each with the number of log records it covers. A snapshot is written to a temporary file,
//!   synced, and renamed into place after the old one moved to `snapshot.prev.bin`, so a crash
//!   leaves at least one whole snapshot. Recovery uses the newest one it can read.
//! - `lock`: held with `flock` while an engine has the directory open.
//!
//! The writer thread keeps its own copy of the learning state, built by applying every record it
//! writes, which is exactly how recovery replays the log. A snapshot is encoded from that copy, so
//! it never takes the engine's lock and never makes a query or a record call wait.
//!
//! Compaction keeps the log bounded. Once the previous snapshot covers `compact_after` records past
//! the log's base, the writer copies the records after that point into `events.tmp` behind a
//! `Base` record, syncs it and renames it over `events.log`. Each step leaves a pair of files that
//! recovers to the same state: before the rename the old log is whole, after it the new log starts
//! where the previous snapshot ends, and the newest snapshot covers at least as much. Records
//! before the base exist only in the snapshots, which is why two are kept.

use crate::engine::{EngineParams, StoreParams};
use slick_predict::log::{RECORD_LEN, Record};
use slick_predict::{Learner, LearnerParams, snapshot};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::JoinHandle;

const LOG: &str = "events.log";
const LOG_TMP: &str = "events.tmp";
const LOG_LOST: &str = "events.unreadable.log";
const SNAPSHOT: &str = "snapshot.bin";
const SNAPSHOT_PREV: &str = "snapshot.prev.bin";
const SNAPSHOT_TMP: &str = "snapshot.tmp";
const LOCK: &str = "lock";
const RECORD: u64 = RECORD_LEN as u64;

/// Test support: how long the writer pauses inside each snapshot, in milliseconds. Tests use it to
/// make a snapshot slow and check that nothing else waits for it.
static SNAPSHOT_PAUSE_MS: AtomicU64 = AtomicU64::new(0);

/// Makes every snapshot pause for `ms` milliseconds while it is written. For tests only.
#[doc(hidden)]
pub fn pause_snapshots_for_tests(ms: u64) {
    SNAPSHOT_PAUSE_MS.store(ms, Ordering::Relaxed);
}

/// The state recovered from a data directory.
pub(crate) struct Recovered {
    pub(crate) learner: Learner,
    /// Records in the log so far, counting those compacted away.
    pub(crate) records: u64,
    files: Files,
    /// True when a fresh snapshot should be written (the old one was missing, stale or ahead of
    /// the log).
    pub(crate) needs_snapshot: bool,
}

/// The open files and what they hold, handed from recovery to the writer.
struct Files {
    /// Held, never read: its `flock` keeps other engines out while this one runs.
    _lock: File,
    log: File,
    /// The number of the log file's first record after its `Base` record (0 without one).
    base: u64,
    /// Records the newest and the previous snapshot on disk cover.
    snapshot: Option<u64>,
    previous: Option<u64>,
}

fn open_private(path: &Path, append: bool) -> io::Result<File> {
    let mut o = OpenOptions::new();
    o.read(true).create(true).mode(0o600);
    if append {
        o.append(true);
    } else {
        o.write(true).truncate(true);
    }
    o.open(path)
}

/// The log's base and the byte offset where its records start.
fn read_base(log: &mut File) -> io::Result<(u64, u64)> {
    let mut first = [0u8; RECORD_LEN];
    log.seek(SeekFrom::Start(0))?;
    match log.read_exact(&mut first) {
        Ok(()) => Ok(match Record::decode(&first) {
            Some(Record::Base { first }) => (first, RECORD),
            _ => (0, 0),
        }),
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok((0, 0)),
        Err(e) => Err(e),
    }
}

/// Loads the newest readable snapshot, replays the log after it and truncates a corrupt tail.
///
/// Fails with `WouldBlock` when another engine, in this process or another, has `dir` open: two
/// writers would interleave their records and each snapshot would count only its own. The lock is
/// an advisory `flock` on the `lock` file, held until the writer thread stops, and the system
/// releases it when a process dies. The log is locked too, which keeps out older versions that
/// locked only the log.
pub(crate) fn recover(dir: &Path, params: &LearnerParams) -> io::Result<Recovered> {
    fs::create_dir_all(dir)?;
    let lock = open_private(&dir.join(LOCK), true)?;
    lock.try_lock()?;
    // Only the lock holder writes the temporaries, so any left over are from a crash.
    for tmp in [SNAPSHOT_TMP, LOG_TMP] {
        match fs::remove_file(dir.join(tmp)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    let mut log = open_private(&dir.join(LOG), true)?;
    log.try_lock()?;
    let (mut base, mut start_byte) = read_base(&mut log)?;
    let end = base + log.metadata()?.len().saturating_sub(start_byte) / RECORD;
    // The newest snapshot whose coverage the log can continue from.
    let mut snapshot = None;
    let mut previous = None;
    let mut loaded = None;
    for (name, slot) in [(SNAPSHOT, &mut snapshot), (SNAPSHOT_PREV, &mut previous)] {
        let Some((l, covered)) = fs::read(dir.join(name))
            .ok()
            .and_then(|b| snapshot::decode(&b, params).ok())
        else {
            continue;
        };
        // Compaction trusts only a snapshot that fits the log; one ahead of it is replaced soon.
        if (base..=end).contains(&covered) {
            *slot = Some(covered);
        }
        if loaded.is_none() && covered >= base {
            loaded = Some((l, covered));
        }
    }
    let (mut learner, start, mut needs_snapshot) = match loaded {
        // The records a snapshot covers are not read again: startup stays proportional to the
        // tail, and damage inside the covered part costs nothing.
        Some((l, covered)) if covered <= end => (l, covered, false),
        // The snapshot is ahead of the log (records lost in a crash): keep its state, and cover
        // the log as it is from now on.
        Some((l, _)) => (l, end, true),
        None if base == 0 => (Learner::new(params), 0, end > 0),
        // The log was compacted and no snapshot that covers its start is readable: its records
        // cannot be replayed without the history before them. Keep the file aside and start over.
        None => {
            drop(log);
            fs::rename(dir.join(LOG), dir.join(LOG_LOST))?;
            log = open_private(&dir.join(LOG), true)?;
            log.try_lock()?;
            (base, start_byte) = (0, 0);
            (snapshot, previous) = (None, None);
            (Learner::new(params), 0, false)
        }
    };
    log.seek(SeekFrom::Start(start_byte + (start - base) * RECORD))?;
    let mut tail = Vec::new();
    log.read_to_end(&mut tail)?;
    let mut valid = start;
    for chunk in tail.as_chunks::<RECORD_LEN>().0 {
        let Some(record) = Record::decode(chunk) else { break };
        if learner.apply(&record).is_err() {
            needs_snapshot = true;
            break;
        }
        valid += 1;
    }
    let valid_len = start_byte + (valid - base) * RECORD;
    if valid_len != log.metadata()?.len() {
        log.set_len(valid_len)?;
    }
    Ok(Recovered {
        learner,
        records: valid,
        files: Files {
            _lock: lock,
            log,
            base,
            snapshot,
            previous,
        },
        needs_snapshot,
    })
}

enum Command {
    Append(Vec<[u8; RECORD_LEN]>),
    Snapshot,
    Reset,
    Flush(Sender<()>),
    Close,
}

/// The handle to the store's writer thread.
pub(crate) struct Store {
    tx: Sender<Command>,
    thread: Option<JoinHandle<()>>,
    errors: Arc<AtomicU64>,
}

impl Store {
    /// Starts the writer thread for `dir` with what `recover` found there.
    pub(crate) fn start(dir: &Path, recovered: Recovered, params: &EngineParams) -> Store {
        let (tx, rx) = channel();
        let errors = Arc::new(AtomicU64::new(0));
        let Recovered {
            learner,
            records,
            files,
            needs_snapshot,
        } = recovered;
        let writer = Writer {
            dir: dir.to_path_buf(),
            files,
            replica: learner,
            replica_ok: true,
            written: records,
            learner_params: params.learner.clone(),
            store: params.store.clone(),
            errors: Arc::clone(&errors),
        };
        let thread = std::thread::Builder::new()
            .name("slick-store".into())
            .spawn(move || writer.run(rx))
            .ok();
        let store = Store { tx, thread, errors };
        if needs_snapshot {
            store.snapshot();
        }
        store
    }

    /// Queues records for the log.
    pub(crate) fn append(&self, records: Vec<[u8; RECORD_LEN]>) {
        self.send(Command::Append(records));
    }

    /// Queues a snapshot of everything appended before it.
    pub(crate) fn snapshot(&self) {
        self.send(Command::Snapshot);
    }

    /// Queues the erasure of the log and the snapshots.
    pub(crate) fn reset(&self) {
        self.send(Command::Reset);
    }

    /// Waits until everything queued so far is written and synced.
    pub(crate) fn flush(&self) {
        let (tx, rx) = channel();
        self.send(Command::Flush(tx));
        // A writer that is gone has nothing left to flush.
        let _ = rx.recv();
    }

    /// Writes a final snapshot and stops the writer.
    pub(crate) fn close(mut self) {
        self.send(Command::Close);
        if let Some(t) = self.thread.take() {
            // A writer that panicked has already lost its data; there is nothing to recover here.
            let _ = t.join();
        }
    }

    /// Write errors so far.
    pub(crate) fn errors(&self) -> u64 {
        self.errors.load(Ordering::Relaxed)
    }

    fn send(&self, c: Command) {
        if self.tx.send(c).is_err() {
            self.errors.fetch_add(1, Ordering::Relaxed);
        }
    }
}

struct Writer {
    dir: PathBuf,
    files: Files,
    /// The learning state of every record written so far.
    replica: Learner,
    /// False once a record failed to apply to the replica; snapshots stop until a reset.
    replica_ok: bool,
    /// Records written so far, counting those compacted away.
    written: u64,
    learner_params: LearnerParams,
    store: StoreParams,
    errors: Arc<AtomicU64>,
}

impl Writer {
    fn run(mut self, rx: Receiver<Command>) {
        let mut buf: Vec<u8> = Vec::with_capacity(4 * 1024);
        while let Ok(c) = rx.recv() {
            let result = match c {
                Command::Append(records) => self.append(&records, &mut buf),
                Command::Snapshot => self.snapshot_and_compact(),
                Command::Reset => self.reset(),
                Command::Flush(done) => {
                    let r = self.files.log.sync_data();
                    // The caller may have stopped waiting; that is fine.
                    let _ = done.send(());
                    r
                }
                Command::Close => {
                    let r = self.snapshot_and_compact().and_then(|_| self.files.log.sync_data());
                    self.count(r);
                    return;
                }
            };
            self.count(result);
        }
    }

    fn count(&self, r: io::Result<()>) {
        if r.is_err() {
            self.errors.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn append(&mut self, records: &[[u8; RECORD_LEN]], buf: &mut Vec<u8>) -> io::Result<()> {
        buf.clear();
        records.iter().for_each(|r| buf.extend_from_slice(r));
        self.files.log.write_all(buf)?;
        self.written += records.len() as u64;
        for r in records {
            let applied = Record::decode(r).is_some_and(|r| self.replica.apply(&r).is_ok());
            if !applied && self.replica_ok {
                self.replica_ok = false;
                self.errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        Ok(())
    }

    fn snapshot_and_compact(&mut self) -> io::Result<()> {
        if !self.replica_ok {
            return Ok(());
        }
        self.write_snapshot()?;
        match self.files.previous {
            Some(p) if p >= self.files.base.saturating_add(self.store.compact_after) => self.compact(p),
            _ => Ok(()),
        }
    }

    fn write_snapshot(&mut self) -> io::Result<()> {
        if self.files.snapshot == Some(self.written) {
            return Ok(());
        }
        let bytes = snapshot::encode(&self.replica, self.written);
        let pause = SNAPSHOT_PAUSE_MS.load(Ordering::Relaxed);
        if pause > 0 {
            std::thread::sleep(std::time::Duration::from_millis(pause));
        }
        // The snapshot covers what is written; sync that first so the rename never makes a
        // snapshot visible that is ahead of the log on disk.
        self.files.log.sync_data()?;
        let tmp = self.dir.join(SNAPSHOT_TMP);
        let mut f = open_private(&tmp, false)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
        if self.files.snapshot.is_some() {
            fs::rename(self.dir.join(SNAPSHOT), self.dir.join(SNAPSHOT_PREV))?;
            self.files.previous = self.files.snapshot;
        }
        fs::rename(&tmp, self.dir.join(SNAPSHOT))?;
        self.files.snapshot = Some(self.written);
        File::open(&self.dir)?.sync_all()
    }

    /// Rewrites the log to start at record `to`, which the previous snapshot covers.
    fn compact(&mut self, to: u64) -> io::Result<()> {
        let start_byte = if self.files.base > 0 { RECORD } else { 0 };
        let mut tail = Vec::new();
        let mut read = File::open(self.dir.join(LOG))?;
        read.seek(SeekFrom::Start(start_byte + (to - self.files.base) * RECORD))?;
        read.read_to_end(&mut tail)?;
        let tmp = self.dir.join(LOG_TMP);
        // Empty any temporary a failed compaction left, then open it for appending like the log.
        drop(open_private(&tmp, false)?);
        let mut log = open_private(&tmp, true)?;
        log.try_lock()?;
        log.write_all(&Record::Base { first: to }.encode())?;
        log.write_all(&tail)?;
        log.sync_all()?;
        fs::rename(&tmp, self.dir.join(LOG))?;
        File::open(&self.dir)?.sync_all()?;
        self.files.log = log;
        self.files.base = to;
        Ok(())
    }

    fn reset(&mut self) -> io::Result<()> {
        self.files.log.set_len(0)?;
        self.files.base = 0;
        self.replica = Learner::new(&self.learner_params);
        self.replica_ok = true;
        self.written = 0;
        self.files.snapshot = None;
        self.files.previous = None;
        for name in [SNAPSHOT, SNAPSHOT_PREV] {
            match fs::remove_file(self.dir.join(name)) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        self.files.log.sync_data()
    }
}
