//! Cancelling walks on a large temporary tree: a build, a rebuild, a subtree rescan and the full
//! walk after lost history stop at the folder where their flag is set and publish nothing.
//!
//! The flag counts folder checks and sets itself after a given number, so each test stops the
//! walk at a known point without racing a second thread or waiting on the clock.

mod support;

use slick_files::{Cancel, Cancelled, Config, Event, FileIndex, Rules, event_flags};
use support::TempTree;

/// Folders in the large tree: 1 root, 40 groups and 40 × 50 leaves.
const FOLDERS: usize = 1 + 40 + 40 * 50;

/// A tree of 2,041 folders, each leaf with one file.
fn large(t: &TempTree) {
    for g in 0..40 {
        for l in 0..50 {
            t.file(&format!("group{g:02}/leaf{l:02}/item.txt"), 1);
        }
    }
}

fn config(t: &TempTree, threads: usize) -> Config {
    let mut c = Config::new(vec![t.root.clone()], Rules::recommended(None));
    c.threads = threads;
    c
}

#[test]
fn a_build_stops_at_the_folder_where_its_flag_is_set() {
    let t = TempTree::new("cancel-build");
    large(&t);
    let (_, full) = FileIndex::build(config(&t, 1));
    assert_eq!(full.dirs, FOLDERS, "the uncancelled walk lists every folder");
    for threads in [1, 4] {
        let stop = Cancel::after(100);
        let got = FileIndex::build_cancellable(config(&t, threads), &stop);
        assert_eq!(got.err(), Some(Cancelled), "{threads} threads");
        assert!(stop.is_cancelled());
    }
    let stop = Cancel::new();
    stop.cancel();
    assert_eq!(
        FileIndex::build_cancellable(config(&t, 2), &stop).err(),
        Some(Cancelled),
        "a flag set before the walk stops it at once"
    );
    let unset = Cancel::new();
    let (idx, walked) = FileIndex::build_cancellable(config(&t, 4), &unset).expect("not cancelled");
    assert_eq!(walked.dirs, FOLDERS);
    assert_eq!(idx.snapshot().len(), FOLDERS + 40 * 50);
}

#[test]
fn every_folder_is_checked_once() {
    let t = TempTree::new("cancel-count");
    large(&t);
    // A flag that lets exactly as many checks pass as there are folders never stops the walk; one
    // check fewer stops it at the last folder.
    for threads in [1, 3] {
        let enough = Cancel::after(FOLDERS as u64);
        assert!(
            FileIndex::build_cancellable(config(&t, threads), &enough).is_ok(),
            "{threads} threads"
        );
        assert!(!enough.is_cancelled());
        let short = Cancel::after(FOLDERS as u64 - 1);
        assert_eq!(
            FileIndex::build_cancellable(config(&t, threads), &short).err(),
            Some(Cancelled),
            "{threads} threads"
        );
    }
}

#[test]
fn a_cancelled_rebuild_keeps_the_published_snapshot() {
    let t = TempTree::new("cancel-rebuild");
    large(&t);
    let (idx, _) = FileIndex::build(config(&t, 2));
    let before = idx.snapshot();
    t.file("group00/leaf00/new.txt", 1);
    let stop = Cancel::after(10);
    assert_eq!(idx.rebuild_cancellable(&stop).err(), Some(Cancelled));
    let after = idx.snapshot();
    assert_eq!(after.generation(), before.generation(), "nothing was published");
    assert_eq!(after.len(), before.len());
    stop.reset();
    let walked = idx
        .rebuild_cancellable(&stop)
        .expect("a reset flag lets the walk finish");
    assert_eq!(walked.dirs, FOLDERS);
    assert_eq!(idx.snapshot().len(), before.len() + 1);
}

#[test]
fn a_cancelled_batch_changes_nothing_and_the_next_one_applies_cleanly() {
    let t = TempTree::new("cancel-apply");
    large(&t);
    let (idx, _) = FileIndex::build(config(&t, 2));
    let before = idx.snapshot();
    t.file("group05/leaf07/added.txt", 1);
    t.file("group39/leaf49/added.txt", 1);
    let root_scan = [Event::new(&t.root, event_flags::MUST_SCAN_SUB_DIRS)];
    let stop = Cancel::after(30);
    assert_eq!(idx.apply_cancellable(&root_scan, &stop).err(), Some(Cancelled));
    let after = idx.snapshot();
    assert_eq!(after.generation(), before.generation(), "nothing was published");
    assert_eq!(after.len(), before.len());
    // The next batch starts from the published snapshot, not from the half-applied one.
    let stats = idx.apply(&root_scan);
    assert!(stats.published);
    assert_eq!(stats.added, 2);
    assert_eq!(idx.snapshot().len(), before.len() + 2);

    // Lost history walks every root again; that walk stops too.
    let lost = [Event::new(&t.root, event_flags::USER_DROPPED)];
    let stop = Cancel::after(5);
    let published = idx.snapshot().generation();
    assert_eq!(idx.apply_cancellable(&lost, &stop).err(), Some(Cancelled));
    assert_eq!(idx.snapshot().generation(), published);
    let stats = idx.apply_cancellable(&lost, &Cancel::new()).expect("not cancelled");
    assert!(stats.full && stats.published);
}
