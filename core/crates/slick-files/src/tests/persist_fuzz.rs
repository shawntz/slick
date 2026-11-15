//! The index file reader against damaged files: every damaged file is refused or, when the
//! damage is undetectable by design, a resealed checksum over a still-valid structure, opened
//! without a panic.

use super::corpus;
use crate::persist::{self, LoadError};
use crate::search::{SearchOptions, Searcher, Serial};
use crate::store::{EntryId, NewEntry, Snapshot, flags};
use std::path::{Path, PathBuf};
use std::sync::Arc;

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!(
            "slick-files-{tag}-{}-{}",
            std::process::id(),
            fastrand::u64(..)
        ));
        std::fs::create_dir_all(&p).expect("temp dir");
        TempDir(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const FP: u64 = 0x5eed;

fn with_dead_slots(seed: u64, n: usize) -> Snapshot {
    let (mut s, dirs) = corpus(seed, n);
    s.rules_hash = FP;
    // Kill a few subtrees so the file holds dead slots, and add a long name.
    for &d in dirs.iter().skip(1).step_by(7).take(5) {
        let parent = s.parent_of(d);
        s.kill_subtree(d);
        let kids: Vec<EntryId> = s.children(parent).filter(|&k| k != d).collect();
        s.link_children(parent, &kids);
    }
    let root = s.roots().next().map_or(0, |r| r.0);
    let long = vec![b'L'; 300];
    let id = s.push(NewEntry {
        parent: root,
        name: &long,
        flags: 0,
        mtime: 5,
        size: 7,
    });
    let mut kids: Vec<EntryId> = s.children(root).collect();
    kids.push(id);
    s.link_children(root, &kids);
    s
}

fn exercise(s: &Snapshot) {
    let snap = Arc::new(s.clone());
    let mut searcher = Searcher::new();
    let mut out = Vec::new();
    let o = SearchOptions {
        now: 1_700_000_000,
        include_hidden: true,
        ..SearchOptions::default()
    };
    for q in [
        "r",
        "readme",
        "docs readme",
        "src/main",
        ".pdf",
        "report pdf",
        "/synthetic/root/",
        "calender",
    ] {
        searcher.search(&snap, q, &o, &Serial, &mut out);
        for h in &out {
            let _ = snap.path(h.id);
        }
    }
    for id in 0..snap.slots() as EntryId {
        let _ = snap.path(id);
        let _ = snap.children(id).count();
    }
    let _ = snap.entries();
}

#[test]
fn round_trip_is_exact_and_searchable() {
    let dir = TempDir::new("roundtrip");
    let path = dir.0.join("index.bin");
    let s = with_dead_slots(21, 9_000);
    persist::write(&path, &s, 77).expect("write");
    let (back, meta) = persist::read(&path, FP).expect("read");
    assert_eq!(meta.event_id, 77);
    assert_eq!(meta.entries, s.len());
    assert_eq!(back.slots(), s.slots());
    assert_eq!(back.entries(), s.entries());
    let (a, b) = (Arc::new(s), Arc::new(back));
    let o = SearchOptions {
        now: 1_700_000_000,
        ..SearchOptions::default()
    };
    let (mut sa, mut sb) = (Searcher::new(), Searcher::new());
    let (mut oa, mut ob) = (Vec::new(), Vec::new());
    for q in [
        "r",
        "rea",
        "docs readme",
        "proj/src main",
        ".md",
        "report pdf",
        "café",
        "LLL",
    ] {
        sa.search(&a, q, &o, &Serial, &mut oa);
        sb.search(&b, q, &o, &Serial, &mut ob);
        assert_eq!(oa, ob, "{q}");
    }
    let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&path).expect("stat").permissions());
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn a_mapped_snapshot_copies_on_write() {
    let dir = TempDir::new("cow");
    let path = dir.0.join("index.bin");
    let s = with_dead_slots(22, 5_000);
    persist::write(&path, &s, 0).expect("write");
    let (mapped, _) = persist::read(&path, FP).expect("read");
    let before = mapped.entries().len();
    let mut w = mapped.clone();
    let root = w.roots().next().map_or(0, |r| r.0);
    let id = w.push(NewEntry {
        parent: root,
        name: b"fresh.txt",
        flags: 0,
        mtime: 9,
        size: 1,
    });
    let mut kids: Vec<EntryId> = w.children(root).collect();
    kids.push(id);
    w.link_children(root, &kids);
    let victim = kids[0];
    w.kill_subtree(victim);
    let kids: Vec<EntryId> = w.children(root).filter(|&k| k != victim).collect();
    w.link_children(root, &kids);
    assert_eq!(mapped.entries().len(), before, "the mapped snapshot is unchanged");
    assert!(w.path(id).is_some_and(|p| p.ends_with(b"/fresh.txt")));
    assert!(mapped.entry(id).is_none());
    // Writing the changed snapshot and reading it back keeps the change.
    let path2 = dir.0.join("index2.bin");
    persist::write(&path2, &w, 0).expect("write");
    let (again, _) = persist::read(&path2, FP).expect("read");
    assert_eq!(again.entries(), w.entries());
}

#[test]
fn other_versions_and_settings_are_refused() {
    let dir = TempDir::new("version");
    let path = dir.0.join("index.bin");
    let s = with_dead_slots(23, 500);
    persist::write(&path, &s, 0).expect("write");
    assert!(matches!(persist::read(&path, FP + 1), Err(LoadError::Mismatch)));
    let mut bytes = std::fs::read(&path).expect("read");
    bytes[8..12].copy_from_slice(&(persist::VERSION + 1).to_le_bytes());
    persist::reseal(&mut bytes);
    std::fs::write(&path, &bytes).expect("write");
    assert!(matches!(persist::read(&path, FP), Err(LoadError::Version(_))));
    std::fs::write(&path, b"").expect("write");
    assert!(matches!(persist::read(&path, FP), Err(LoadError::Corrupt(_))));
    assert!(matches!(
        persist::read(&dir.0.join("missing"), FP),
        Err(LoadError::Io(_))
    ));
}

fn damage(rng: &mut fastrand::Rng, b: &mut Vec<u8>) {
    match rng.u8(..6) {
        0 => {
            let i = rng.usize(..b.len());
            b[i] ^= 1 << rng.u8(..8);
        }
        1 => {
            let i = rng.usize(..b.len());
            b[i] = rng.u8(..);
        }
        2 => b.truncate(rng.usize(..b.len())),
        3 => b.extend((0..rng.usize(1..200)).map(|_| rng.u8(..))),
        4 => {
            let i = rng.usize(..b.len());
            let n = rng.usize(1..64).min(b.len() - i);
            b[i..i + n].fill(0);
        }
        _ => {
            let i = rng.usize(..b.len().saturating_sub(4));
            b[i..i + 4].copy_from_slice(&rng.u32(..).to_le_bytes());
        }
    }
}

fn write_bytes(path: &Path, b: &[u8]) {
    std::fs::write(path, b).expect("write");
}

#[test]
fn damaged_files_are_refused_without_panics() {
    let dir = TempDir::new("fuzz");
    let path = dir.0.join("index.bin");
    let s = with_dead_slots(24, 400);
    persist::write(&path, &s, 3).expect("write");
    let good = std::fs::read(&path).expect("read");
    let want = s.entries();
    let mut rng = fastrand::Rng::with_seed(2026);
    let mut refused = 0;
    let mut opened_resealed = 0;
    for i in 0..3_000 {
        let mut b = good.clone();
        for _ in 0..rng.usize(1..4) {
            if b.is_empty() {
                break;
            }
            damage(&mut rng, &mut b);
        }
        // Every other file gets a valid checksum, so the structural checks must catch it.
        let resealed = i % 2 == 1 && b.len() >= 128;
        if resealed {
            persist::reseal(&mut b);
        }
        write_bytes(&path, &b);
        match persist::read(&path, FP) {
            Err(_) => refused += 1,
            Ok((snap, _)) => {
                if resealed {
                    opened_resealed += 1;
                    exercise(&snap);
                } else {
                    assert_eq!(snap.entries(), want, "an unsealed change must be refused");
                }
            }
        }
    }
    assert!(refused > 1_500, "refused {refused}");
    eprintln!("refused {refused} of 3000, opened {opened_resealed} resealed files");
}

#[test]
fn flags_survive_the_round_trip() {
    let dir = TempDir::new("flags");
    let path = dir.0.join("index.bin");
    let s = with_dead_slots(25, 2_000);
    persist::write(&path, &s, 0).expect("write");
    let (back, _) = persist::read(&path, FP).expect("read");
    let count = |s: &Snapshot, f: u8| s.entries().iter().filter(|(_, e)| e.flags & f != 0).count();
    for f in [flags::DIR, flags::PACKAGE, flags::HIDDEN, flags::SYMLINK, flags::ROOT] {
        assert_eq!(count(&back, f), count(&s, f), "flag {f}");
    }
}
