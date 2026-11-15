//! The walker on real temporary trees: rules, packages, symbolic links, unreadable folders,
//! vanishing files, and the three enumeration methods.

mod support;

use slick_files::walk::{self, Method};
use slick_files::{Config, FileIndex, Rules, flags};
use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use support::{TempTree, rel};

fn fixture(t: &TempTree) {
    t.file("docs/README.md", 10);
    t.file("docs/guide.pdf", 2_000);
    t.file("proj/src/main.rs", 30);
    t.file("proj/node_modules/pkg/index.js", 5);
    t.file("proj/.git/HEAD", 5);
    t.file("proj/build/out.o", 5);
    t.file("Editor.app/Contents/Info.plist", 5);
    t.file(".hidden-notes.txt", 5);
    t.file("Library/Caches/blob", 5);
    t.file("locked/secret.txt", 5);
    std::os::unix::fs::symlink("/private/tmp", t.path("link-out")).expect("symlink");
    std::os::unix::fs::symlink(t.path("docs"), t.path("link-in")).expect("symlink");
    std::fs::set_permissions(t.path("locked"), std::fs::Permissions::from_mode(0o000)).expect("chmod");
}

fn rules_for(t: &TempTree) -> Rules {
    let mut r = Rules::recommended(None);
    r.skip_paths = vec![t.path("Library")];
    r
}

/// Relative path to flags, for every indexed entry below the root.
fn listing(idx: &FileIndex, t: &TempTree) -> BTreeMap<String, u8> {
    idx.snapshot()
        .entries()
        .into_iter()
        .map(|(p, e)| (rel(&t.root, &p), e.flags))
        .collect()
}

#[test]
fn walks_with_rules_links_packages_and_locked_folders() {
    let t = TempTree::new("rules");
    fixture(&t);
    let (idx, stats) = FileIndex::build(Config::new(vec![t.root.clone()], rules_for(&t)));
    let got = listing(&idx, &t);
    let want: BTreeMap<String, u8> = [
        ("", flags::DIR | flags::ROOT),
        ("/docs", flags::DIR),
        ("/docs/README.md", 0),
        ("/docs/guide.pdf", 0),
        ("/proj", flags::DIR),
        ("/proj/src", flags::DIR),
        ("/proj/src/main.rs", 0),
        ("/Editor.app", flags::DIR | flags::PACKAGE),
        ("/locked", flags::DIR | flags::UNREADABLE),
        ("/link-out", flags::SYMLINK),
        ("/link-in", flags::SYMLINK),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    assert_eq!(got, want);
    assert_eq!(stats.unreadable, 1);
    let snap = idx.snapshot();
    let (pdf, _) = snap
        .lookup(t.path("docs/guide.pdf").as_os_str().as_encoded_bytes())
        .expect("found");
    assert_eq!(snap.entry(pdf).and_then(|e| e.size), Some(2_000));
}

#[test]
fn hidden_entries_are_indexed_only_when_asked() {
    let t = TempTree::new("hidden");
    fixture(&t);
    let mut r = rules_for(&t);
    r.include_hidden = true;
    let (idx, _) = FileIndex::build(Config::new(vec![t.root.clone()], r));
    let got = listing(&idx, &t);
    assert_eq!(got.get("/.hidden-notes.txt"), Some(&flags::HIDDEN));
    assert!(
        !got.contains_key("/proj/.git"),
        ".git is a skipped name even when hidden names are on"
    );
}

#[test]
fn every_method_sees_the_same_tree() {
    let t = TempTree::new("methods");
    for i in 0..40 {
        t.file(&format!("d{}/e{}/f{i}.txt", i % 5, i % 3), i);
    }
    let r = Rules::everything();
    let a = walk::measure(&t.root, &r, 1, Method::Bulk).expect("bulk");
    let b = walk::measure(&t.root, &r, 4, Method::Bulk).expect("bulk threads");
    let c = walk::measure(&t.root, &r, 1, Method::ReaddirStat).expect("readdir stat");
    let d = walk::measure(&t.root, &r, 3, Method::Readdir).expect("readdir");
    for s in [b, c, d] {
        assert_eq!((s.dirs, s.entries, s.unreadable), (a.dirs, a.entries, a.unreadable));
    }
    let listed = walk::list_folder(&t.path("d0"), &r).expect("list");
    assert!(listed.iter().any(|e| e.name == b"e0" && e.flags & flags::DIR != 0));
}

#[test]
fn a_root_that_is_missing_is_kept_and_found_later() {
    let t = TempTree::new("missing-root");
    let root = t.path("later");
    let (idx, stats) = FileIndex::build(Config::new(vec![root.clone()], Rules::everything()));
    assert_eq!(stats.unreadable, 1);
    assert_eq!(idx.snapshot().len(), 1);
    t.file("later/a.txt", 1);
    let u = idx.apply(&[slick_files::Event::new(&root, slick_files::event_flags::ITEM_CREATED)]);
    assert!(u.published);
    let names: Vec<String> = listing(&idx, &t).into_keys().collect();
    assert_eq!(names, vec!["/later".to_string(), "/later/a.txt".to_string()]);
}

#[test]
fn walking_while_files_vanish_does_not_fail() {
    let t = TempTree::new("vanish");
    for i in 0..400 {
        t.file(&format!("a{}/b{}/c{i}.txt", i % 10, i % 7), 1);
    }
    let root = t.root.clone();
    let stop = std::sync::atomic::AtomicBool::new(false);
    std::thread::scope(|s| {
        s.spawn(|| {
            let mut i = 0;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let d = root.join(format!("a{}", i % 10));
                let _ = std::fs::remove_dir_all(&d);
                let _ = std::fs::create_dir_all(d.join("b0"));
                let _ = std::fs::write(d.join("b0/new.txt"), b"x");
                i += 1;
            }
        });
        for _ in 0..20 {
            let (idx, _) = FileIndex::build(Config::new(vec![root.clone()], Rules::everything()));
            assert!(!idx.snapshot().is_empty());
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    });
}

#[test]
fn symlinked_root_is_resolved_once() {
    let t = TempTree::new("linkroot");
    t.file("real/x.txt", 1);
    let link: PathBuf = t.path("alias");
    std::os::unix::fs::symlink(t.path("real"), &link).expect("symlink");
    let (idx, _) = FileIndex::build(Config::new(vec![link], Rules::everything()));
    let paths: Vec<String> = idx
        .snapshot()
        .entries()
        .into_iter()
        .map(|(p, _)| rel(&t.root, &p))
        .collect();
    assert_eq!(paths, vec!["/real".to_string(), "/real/x.txt".to_string()]);
}

#[test]
fn a_folder_listed_from_disk_says_why_it_failed() {
    let t = TempTree::new("list-folder");
    fixture(&t);
    let r = rules_for(&t);
    let root = walk::list_folder_checked(&t.root, &r).expect("list");
    assert!(root.complete);
    let names: Vec<String> = root
        .entries
        .iter()
        .map(|e| String::from_utf8_lossy(&e.name).into_owned())
        .collect();
    assert_eq!(
        names,
        ["Editor.app", "docs", "link-in", "link-out", "locked", "proj"],
        "sorted by name, with the rules applied: no hidden name and no skipped Library"
    );
    let app = &root.entries[0];
    assert_eq!(app.flags, flags::DIR | flags::PACKAGE);
    assert_eq!(app.size, None, "a folder has no size");
    let docs = walk::list_folder_checked(&t.path("docs"), &r).expect("list docs");
    assert_eq!(
        docs.entries
            .iter()
            .find(|e| e.name == b"guide.pdf")
            .and_then(|e| e.size),
        Some(2_000)
    );
    let kind = |p: PathBuf| walk::list_folder_checked(&p, &r).err().map(|e| e.kind());
    assert_eq!(kind(t.path("missing")), Some(std::io::ErrorKind::NotFound));
    assert_eq!(kind(t.path("docs/guide.pdf")), Some(std::io::ErrorKind::NotADirectory));
    assert_eq!(
        kind(t.path("link-in")),
        Some(std::io::ErrorKind::NotADirectory),
        "a link is never followed"
    );
    assert_eq!(kind(t.path("locked")), Some(std::io::ErrorKind::PermissionDenied));
    support::unlock_all(&t.root);
}
