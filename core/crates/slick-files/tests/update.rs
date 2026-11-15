//! Incremental updates against a fresh scan: after any sequence of changes and the events
//! FSEvents would report for them, the index equals a new walk of the same tree.

mod support;

use slick_files::event_flags as ef;
use slick_files::{Config, Event, FileIndex, Rules};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use support::{TempTree, rel, set_mtime, unlock_all};

type Facts = BTreeMap<String, (u8, u32, Option<u64>)>;

fn facts(idx: &FileIndex, root: &Path) -> Facts {
    idx.snapshot()
        .entries()
        .into_iter()
        .map(|(p, e)| (rel(root, &p), (e.flags, e.mtime, e.size)))
        .collect()
}

fn fresh(config: &Config, root: &Path) -> Facts {
    let (idx, _) = FileIndex::build(config.clone());
    facts(&idx, root)
}

fn diff(a: &Facts, b: &Facts) -> String {
    let mut out = String::new();
    for (k, v) in a {
        match b.get(k) {
            None => out.push_str(&format!("- {k} {v:?}\n")),
            Some(w) if w != v => out.push_str(&format!("~ {k} {v:?} -> {w:?}\n")),
            _ => {}
        }
    }
    for (k, v) in b {
        if !a.contains_key(k) {
            out.push_str(&format!("+ {k} {v:?}\n"));
        }
    }
    out
}

fn config(root: &Path) -> Config {
    let mut r = Rules::recommended(None);
    r.leaf_extensions.push("bundle".into());
    Config::new(vec![root.to_path_buf()], r)
}

const WORDS: &[&str] = &[
    "docs", "readme", "proj", "src", "main", "notes", "Report", "img", "plan", "x",
];

fn random_name(rng: &mut fastrand::Rng) -> String {
    let mut s = WORDS[rng.usize(..WORDS.len())].to_string();
    if rng.bool() {
        s.push_str(&rng.u16(..100).to_string());
    }
    match rng.u8(..10) {
        0 => s.insert(0, '.'),
        1 => s = "node_modules".into(),
        2 => s.push_str(".bundle"),
        _ => {}
    }
    s
}

/// Every folder and file below `root`, following no links.
fn list_all(root: &Path) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() {
                dirs.push(e.path());
                stack.push(e.path());
            } else if t.is_file() {
                files.push(e.path());
            }
        }
    }
    dirs.sort();
    files.sort();
    (dirs, files)
}

/// Makes one random change and returns the events a file-level stream would report.
fn mutate(rng: &mut fastrand::Rng, root: &Path) -> Vec<Event> {
    let (dirs, files) = list_all(root);
    let mut all_dirs = vec![root.to_path_buf()];
    all_dirs.extend(dirs.iter().cloned());
    let pick_dir = |rng: &mut fastrand::Rng| all_dirs[rng.usize(..all_dirs.len())].clone();
    match rng.u8(..12) {
        0 | 1 => {
            let p = pick_dir(rng).join(format!("{}.txt", random_name(rng)));
            let _ = fs::write(&p, vec![b'y'; rng.usize(0..500)]);
            vec![Event::new(&p, ef::ITEM_CREATED | ef::ITEM_IS_FILE)]
        }
        2 => {
            // A new folder with content, as `cp -R` makes it: one event per created item.
            let d = pick_dir(rng).join(random_name(rng));
            let _ = fs::create_dir_all(d.join("inner"));
            let _ = fs::write(d.join("inner/a.md"), b"a");
            let _ = fs::write(d.join("b.pdf"), b"b");
            vec![
                Event::new(&d, ef::ITEM_CREATED | ef::ITEM_IS_DIR),
                Event::new(d.join("inner"), ef::ITEM_CREATED | ef::ITEM_IS_DIR),
                Event::new(d.join("inner/a.md"), ef::ITEM_CREATED | ef::ITEM_IS_FILE),
                Event::new(d.join("b.pdf"), ef::ITEM_CREATED | ef::ITEM_IS_FILE),
            ]
        }
        3 if !files.is_empty() => {
            let f = &files[rng.usize(..files.len())];
            let _ = fs::remove_file(f);
            vec![Event::new(f, ef::ITEM_REMOVED | ef::ITEM_IS_FILE)]
        }
        4 if !dirs.is_empty() => {
            let d = &dirs[rng.usize(..dirs.len())];
            unlock_all(d);
            let _ = fs::remove_dir_all(d);
            vec![Event::new(d, ef::ITEM_REMOVED | ef::ITEM_IS_DIR)]
        }
        5 if !files.is_empty() => {
            let f = &files[rng.usize(..files.len())];
            let to = f.with_file_name(format!("{}.md", random_name(rng)));
            let _ = fs::rename(f, &to);
            vec![Event::new(f, ef::ITEM_RENAMED), Event::new(&to, ef::ITEM_RENAMED)]
        }
        6 if !dirs.is_empty() => {
            // Move a subtree somewhere else, not inside itself.
            let d = dirs[rng.usize(..dirs.len())].clone();
            let target = pick_dir(rng);
            if target.starts_with(&d) {
                return Vec::new();
            }
            let to = target.join(format!("moved-{}", random_name(rng)));
            if fs::rename(&d, &to).is_err() {
                return Vec::new();
            }
            vec![
                Event::new(&d, ef::ITEM_RENAMED | ef::ITEM_IS_DIR),
                Event::new(&to, ef::ITEM_RENAMED | ef::ITEM_IS_DIR),
            ]
        }
        7 if !files.is_empty() => {
            let f = &files[rng.usize(..files.len())];
            set_mtime(f, rng.u64(1..100_000_000));
            vec![Event::new(f, ef::ITEM_MODIFIED | ef::ITEM_IS_FILE)]
        }
        8 if !files.is_empty() => {
            // A file replaced by a folder of the same name.
            let f = &files[rng.usize(..files.len())];
            let _ = fs::remove_file(f);
            let _ = fs::create_dir_all(f.join("child"));
            vec![Event::new(f, ef::ITEM_REMOVED | ef::ITEM_CREATED)]
        }
        9 => {
            let d = pick_dir(rng);
            let l = d.join(format!("link-{}", rng.u16(..1000)));
            let _ = std::os::unix::fs::symlink(&all_dirs[rng.usize(..all_dirs.len())], &l);
            vec![Event::new(&l, ef::ITEM_CREATED | ef::ITEM_IS_SYMLINK)]
        }
        10 if !dirs.is_empty() => {
            // A folder that becomes unreadable, or readable again.
            let d = &dirs[rng.usize(..dirs.len())];
            let locked = fs::metadata(d).is_ok_and(|m| m.permissions().mode() & 0o700 == 0);
            let mode = if locked { 0o755 } else { 0o000 };
            let _ = fs::set_permissions(d, fs::Permissions::from_mode(mode));
            vec![Event::new(d, 0x400 /* inode metadata */)]
        }
        _ => {
            // Dependency churn: every created item is reported, and all of it is skipped.
            let nm = pick_dir(rng).join("node_modules");
            let f = nm.join("dep/index.js");
            let _ = fs::create_dir_all(nm.join("dep"));
            let _ = fs::write(&f, b"x");
            vec![
                Event::new(&nm, ef::ITEM_CREATED | ef::ITEM_IS_DIR),
                Event::new(nm.join("dep"), ef::ITEM_CREATED | ef::ITEM_IS_DIR),
                Event::new(&f, ef::ITEM_CREATED | ef::ITEM_IS_FILE),
            ]
        }
    }
}

fn seed_tree(t: &TempTree, rng: &mut fastrand::Rng) {
    for i in 0..60 {
        let depth = rng.usize(0..4);
        let mut p = String::new();
        for _ in 0..depth {
            p.push_str(&random_name(rng));
            p.push('/');
        }
        p.push_str(&format!("{}-{i}.txt", random_name(rng)));
        t.file(&p, rng.usize(0..100));
    }
}

#[test]
fn random_changes_with_file_events_equal_a_fresh_scan() {
    let mut total = slick_files::UpdateStats::default();
    for seed in 0..12u64 {
        let t = TempTree::new(&format!("prop{seed}"));
        let mut rng = fastrand::Rng::with_seed(seed);
        seed_tree(&t, &mut rng);
        let cfg = config(&t.root);
        let (idx, _) = FileIndex::build(cfg.clone());
        for step in 0..30 {
            let mut events = Vec::new();
            for _ in 0..rng.usize(1..4) {
                events.extend(mutate(&mut rng, &t.root));
            }
            let u = idx.apply(&events);
            total.added += u.added;
            total.removed += u.removed;
            total.changed += u.changed;
            total.ignored += u.ignored;
            total.rescans += u.rescans;
            let got = facts(&idx, &t.root);
            let want = fresh(&cfg, &t.root);
            assert!(
                got == want,
                "seed {seed} step {step} events {events:?}\n{}",
                diff(&got, &want)
            );
        }
    }
    eprintln!("{total:?}");
    assert!(total.added > 50 && total.removed > 50 && total.changed > 5 && total.ignored > 20);
}

#[test]
fn folder_level_events_equal_a_fresh_scan() {
    // A stream without file events reports the folders whose contents changed.
    for seed in 100..106u64 {
        let t = TempTree::new(&format!("dirlevel{seed}"));
        let mut rng = fastrand::Rng::with_seed(seed);
        seed_tree(&t, &mut rng);
        let cfg = config(&t.root);
        let (idx, _) = FileIndex::build(cfg.clone());
        for step in 0..20 {
            // Permission changes are modelled as item events: a folder-level stream may report
            // only the parent, whose listing does not show that a child became unreadable.
            let events: Vec<Event> = mutate(&mut rng, &t.root)
                .into_iter()
                .flat_map(|e| {
                    let p = PathBuf::from(String::from_utf8_lossy(&e.path).into_owned());
                    let mut v: Vec<Event> = p.parent().map(|d| Event::new(d, 0)).into_iter().collect();
                    if e.flags == 0x400 {
                        v.push(e);
                    }
                    v
                })
                .collect();
            idx.apply(&events);
            let got = facts(&idx, &t.root);
            let want = fresh(&cfg, &t.root);
            assert!(got == want, "seed {seed} step {step}\n{}", diff(&got, &want));
        }
    }
}

#[test]
fn must_scan_subdirs_and_dropped_history_rescan() {
    let t = TempTree::new("dropped");
    let mut rng = fastrand::Rng::with_seed(7);
    seed_tree(&t, &mut rng);
    let cfg = config(&t.root);
    let (idx, _) = FileIndex::build(cfg.clone());
    // Changes nobody reports, then one coalesced event.
    for _ in 0..10 {
        mutate(&mut rng, &t.root);
    }
    let u = idx.apply(&[Event::new(&t.root, ef::MUST_SCAN_SUB_DIRS)]);
    assert!(!u.full && u.rescans > 1);
    assert_eq!(facts(&idx, &t.root), fresh(&cfg, &t.root));
    for _ in 0..10 {
        mutate(&mut rng, &t.root);
    }
    let u = idx.apply(&[Event::new("/", ef::KERNEL_DROPPED)]);
    assert!(u.full);
    assert_eq!(facts(&idx, &t.root), fresh(&cfg, &t.root));
}

#[test]
fn events_outside_the_roots_or_below_skipped_names_are_ignored() {
    let t = TempTree::new("ignored");
    t.file("a/b.txt", 1);
    let cfg = config(&t.root);
    let (idx, _) = FileIndex::build(cfg);
    let before = idx.snapshot().generation();
    let u = idx.apply(&[
        Event::new("/elsewhere/file", ef::ITEM_CREATED),
        Event::new(t.path("a/node_modules/x/y.js"), ef::ITEM_CREATED),
        Event::new(t.path(".git/index"), ef::ITEM_MODIFIED),
        Event::new(t.path("x.bundle/Contents/z"), ef::ITEM_CREATED),
    ]);
    assert_eq!((u.ignored, u.rescans, u.published), (4, 0, false));
    assert_eq!(idx.snapshot().generation(), before);
}

#[test]
fn removing_and_restoring_the_root() {
    let t = TempTree::new("rootgone");
    let root = t.path("r");
    t.file("r/a/b.txt", 1);
    let cfg = config(&root);
    let (idx, _) = FileIndex::build(cfg.clone());
    fs::rename(&root, t.path("r-away")).expect("move root away");
    idx.apply(&[Event::new(&root, ef::ROOT_CHANGED)]);
    assert_eq!(idx.snapshot().len(), 1, "only the root entry stays");
    fs::rename(t.path("r-away"), &root).expect("move root back");
    idx.apply(&[Event::new(&root, ef::ROOT_CHANGED)]);
    assert_eq!(facts(&idx, &root), fresh(&cfg, &root));
}

#[test]
fn an_opened_file_takes_updates() {
    let t = TempTree::new("persisted");
    let root = t.path("r");
    let mut rng = fastrand::Rng::with_seed(31);
    for i in 0..300 {
        t.file(
            &format!("r/{}/{}-{i}.txt", random_name(&mut rng), random_name(&mut rng)),
            3,
        );
    }
    let cfg = config(&root);
    let (idx, _) = FileIndex::build(cfg.clone());
    let file = t.path("index.bin");
    idx.save(&file, 1234).expect("save");
    drop(idx);
    let (idx, meta) = FileIndex::open(&file, cfg.clone()).expect("open");
    assert_eq!(meta.event_id, 1234);
    assert_eq!(facts(&idx, &root), fresh(&cfg, &root));
    for _ in 0..15 {
        let ev = mutate(&mut rng, &root);
        idx.apply(&ev);
        assert_eq!(facts(&idx, &root), fresh(&cfg, &root));
    }
    // Saving over the open file is atomic: the mapped snapshot keeps reading the old one.
    let old = idx.snapshot();
    idx.save(&file, 99).expect("save again");
    let _ = old.entries();
    let other = config(&t.path("other"));
    assert!(matches!(
        FileIndex::open(&file, other),
        Err(slick_files::LoadError::Mismatch)
    ));
}

#[test]
fn readers_search_while_the_writer_updates() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    let t = TempTree::new("concurrent");
    let mut rng = fastrand::Rng::with_seed(77);
    seed_tree(&t, &mut rng);
    let cfg = config(&t.root);
    let idx = Arc::new(FileIndex::build(cfg).0);
    let stop = AtomicBool::new(false);
    std::thread::scope(|s| {
        for r in 0..3 {
            let idx = &idx;
            let stop = &stop;
            s.spawn(move || {
                let mut searcher = slick_files::Searcher::new();
                let mut out = Vec::new();
                let o = slick_files::SearchOptions::default();
                let queries = ["r", "docs", "main readme", ".txt", "notes/", "proj src"];
                let mut i = r;
                while !stop.load(Ordering::Relaxed) {
                    let snap = idx.snapshot();
                    searcher.search(&snap, queries[i % queries.len()], &o, &slick_files::Serial, &mut out);
                    for h in &out {
                        assert!(snap.path(h.id).is_some(), "a hit resolves in its own snapshot");
                    }
                    i += 1;
                }
            });
        }
        for _ in 0..40 {
            let ev = mutate(&mut rng, &t.root);
            idx.apply(&ev);
        }
        stop.store(true, Ordering::Relaxed);
    });
}
