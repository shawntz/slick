//! A root kept inside a folder another root skips, as iCloud Drive sits inside a skipped Library
//! folder: what the walk indexes, how events reach it, and that updates equal a fresh walk.

mod support;

use slick_files::event_flags as ef;
use slick_files::{Config, Event, FileIndex, Rules};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use support::{TempTree, rel};

const CLOUD: &str = "Library/Mobile Documents";

fn tree() -> TempTree {
    let t = TempTree::new("nested");
    t.file("docs/plan.md", 3);
    t.file("Library/Caches/blob.bin", 3);
    t.file("Library/Preferences/settings.plist", 3);
    t.file(&format!("{CLOUD}/drive/notes.md"), 3);
    t.file(&format!("{CLOUD}/drive/sub/deep.txt"), 3);
    t
}

fn config(t: &TempTree, keep: bool) -> Config {
    let mut c = Config::new(vec![t.root.clone(), t.path(CLOUD)], Rules::recommended(Some(&t.root)));
    c.keep_unreached_roots = keep;
    c
}

/// Relative path to (flags, size) for every entry.
fn facts(idx: &FileIndex, t: &TempTree) -> BTreeMap<String, (u8, Option<u64>)> {
    idx.snapshot()
        .entries()
        .into_iter()
        .map(|(p, e)| (rel(&t.root, &p), (e.flags, e.size)))
        .collect()
}

fn fresh(t: &TempTree) -> BTreeMap<String, (u8, Option<u64>)> {
    facts(&FileIndex::build(config(t, true)).0, t)
}

#[test]
fn the_nested_root_is_kept_only_when_asked() {
    let t = tree();
    let (dropped, _) = FileIndex::build(config(&t, false));
    let names: Vec<String> = facts(&dropped, &t).into_keys().collect();
    assert!(names.iter().all(|n| !n.contains("Mobile")), "{names:?}");

    let (kept, _) = FileIndex::build(config(&t, true));
    let f = facts(&kept, &t);
    for want in [
        "/docs/plan.md",
        "/Library/Mobile Documents",
        "/Library/Mobile Documents/drive/notes.md",
        "/Library/Mobile Documents/drive/sub/deep.txt",
    ] {
        assert!(f.contains_key(want), "{want} missing from {:?}", f.keys());
    }
    assert!(
        f.keys().all(|k| !k.contains("Caches") && !k.contains("Preferences")),
        "the rest of Library stays skipped: {:?}",
        f.keys()
    );
    let roots: Vec<PathBuf> = kept
        .snapshot()
        .roots()
        .map(|(_, p)| PathBuf::from(String::from_utf8_lossy(p).into_owned()))
        .collect();
    assert_eq!(roots, vec![t.root.clone(), t.path(CLOUD)]);
    let snap = kept.snapshot();
    let (id, exact) = snap
        .lookup(t.path(CLOUD).as_os_str().as_encoded_bytes())
        .expect("found");
    assert!(exact && roots.len() == 2);
    assert_eq!(
        snap.entry(id).map(|e| e.parent),
        Some(slick_files::NONE),
        "a root of its own"
    );
}

#[test]
fn events_inside_the_nested_root_reach_it() {
    let t = tree();
    let (idx, _) = FileIndex::build(config(&t, true));
    let p = t.file(&format!("{CLOUD}/drive/new.md"), 5);
    let stats = idx.apply(&[Event::new(&p, ef::ITEM_CREATED | ef::ITEM_IS_FILE)]);
    assert_eq!(stats.added, 1);
    // A folder-level event for the nested root's own folder.
    let q = t.file(&format!("{CLOUD}/top.txt"), 5);
    let stats = idx.apply(&[Event::new(q.parent().expect("parent"), 0)]);
    assert!(stats.added >= 1);
    assert_eq!(facts(&idx, &t), fresh(&t));
    // Churn elsewhere in the skipped Library folder reaches nothing.
    let c = t.file("Library/Caches/more.bin", 1);
    let stats = idx.apply(&[Event::new(&c, ef::ITEM_CREATED | ef::ITEM_IS_FILE)]);
    assert_eq!((stats.ignored, stats.rescans), (1, 0));
}

#[test]
fn a_move_above_the_nested_root_is_noticed() {
    let t = tree();
    let (idx, _) = FileIndex::build(config(&t, true));
    let library = t.path("Library");
    let moved = t.path("Library Moved");
    fs::rename(&library, &moved).expect("rename");
    let stats = idx.apply(&[Event::new(&library, ef::ITEM_RENAMED | ef::ITEM_IS_DIR)]);
    assert!(stats.published && stats.removed >= 4, "{stats:?}");
    let f = facts(&idx, &t);
    let cloud = f.get("/Library/Mobile Documents").expect("the root stays as an entry");
    assert_ne!(cloud.0 & slick_files::flags::UNREADABLE, 0, "and is marked unreadable");
    assert!(
        f.keys().all(|k| !k.starts_with("/Library/Mobile Documents/")),
        "{:?}",
        f.keys()
    );

    fs::rename(&moved, &library).expect("rename back");
    idx.apply(&[Event::new(&library, ef::ITEM_RENAMED | ef::ITEM_IS_DIR)]);
    assert_eq!(facts(&idx, &t), fresh(&t), "moved back, it is walked again");
}

#[test]
fn must_scan_sub_dirs_at_the_outer_root_rescans_the_nested_one() {
    let t = tree();
    let (idx, _) = FileIndex::build(config(&t, true));
    t.file(&format!("{CLOUD}/drive/sub/added.txt"), 9);
    fs::remove_file(t.path(&format!("{CLOUD}/drive/notes.md"))).expect("remove");
    t.file("docs/also.md", 9);
    idx.apply(&[Event::new(&t.root, ef::MUST_SCAN_SUB_DIRS)]);
    assert_eq!(facts(&idx, &t), fresh(&t));
}

#[test]
fn a_saved_index_is_reused_only_with_the_same_choice() {
    let t = tree();
    let file = t.path("index.bin");
    let (idx, _) = FileIndex::build(config(&t, true));
    idx.save(&file, 7).expect("save");
    assert!(FileIndex::open(&file, config(&t, true)).is_ok());
    assert!(
        FileIndex::open(&file, config(&t, false)).is_err(),
        "dropping the nested root changes the roots, so the file does not fit"
    );
}
