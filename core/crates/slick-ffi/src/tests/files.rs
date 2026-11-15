//! The file index through the C ABI: build, search with narrowing, paths, highlights, browse,
//! events, save and open, snapshots, parallel parts, allocations and hostile arguments.
//!
//! Disk trees are synthetic and live under the system temporary folder, never the home folder.
//! They are removed on drop. Larger indexes come from `slick_files_synthetic` and never touch the
//! disk.

use super::alloc;
use super::*;
use crate::files::*;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

const BAD: i32 = SlickStatus::InvalidArgument as i32;
const NULL: i32 = SlickStatus::NullPointer as i32;
const UTF8: i32 = SlickStatus::InvalidUtf8 as i32;
const SMALL: i32 = SlickStatus::BufferTooSmall as i32;
const IO: i32 = SlickStatus::Io as i32;

/// FSEvents flags the tests send.
const CREATED: u32 = 0x100;
const REMOVED: u32 = 0x200;
const IS_FILE: u32 = 0x1_0000;

/// A temporary folder, removed on drop.
struct Tree(PathBuf);

impl Tree {
    fn new(tag: &str) -> Tree {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("slick-ffi-{tag}-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create the tree");
        Tree(fs::canonicalize(&dir).expect("canonical path"))
    }

    /// The synthetic home the main tests index.
    fn home() -> Tree {
        let t = Tree::new("home");
        for (rel, size) in [
            ("docs/readme.md", 120),
            ("docs/report 2024.pdf", 4_000),
            ("docs/Meeting Notes.txt", 10),
            ("projects/app/src/main.rs", 300),
            ("projects/app/src/utils.rs", 200),
            ("projects/app/README.md", 50),
            ("photos/beach.jpg", 9_000),
            ("café/crème brûlée.txt", 5),
            (".hidden/secret.txt", 1),
            ("node_modules/pkg/index.js", 1),
            ("Library/cache.db", 1),
            ("Tool.app/Contents/Info.plist", 1),
        ] {
            t.file(rel, size);
        }
        t
    }

    fn path(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }

    fn file(&self, rel: &str, size: usize) -> PathBuf {
        let p = self.path(rel);
        if let Some(d) = p.parent() {
            fs::create_dir_all(d).expect("mkdir");
        }
        fs::write(&p, vec![b'x'; size]).expect("write");
        p
    }

    fn bytes(&self, rel: &str) -> Vec<u8> {
        let p = if rel.is_empty() { self.0.clone() } else { self.path(rel) };
        p.as_os_str().as_bytes().to_vec()
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A config and the strings buffer its spans point into.
struct Setup {
    config: SlickFilesConfig,
    strings: Vec<u8>,
}

impl Setup {
    fn new(roots: &[&Path], home: Option<&Path>, flags: u32) -> Setup {
        let mut strings = Vec::new();
        let mut put = |items: &[&[u8]]| {
            let start = strings.len() as u32;
            for (i, it) in items.iter().enumerate() {
                if i > 0 {
                    strings.push(0);
                }
                strings.extend_from_slice(it);
            }
            (start, strings.len() as u32 - start)
        };
        let roots: Vec<&[u8]> = roots.iter().map(|r| r.as_os_str().as_bytes()).collect();
        let (roots_start, roots_len) = put(&roots);
        let (home_start, home_len) = put(&[home.map_or(&b""[..], |h| h.as_os_str().as_bytes())]);
        let config = SlickFilesConfig {
            roots_start,
            roots_len,
            home_start,
            home_len,
            threads: 2,
            flags,
            ..SlickFilesConfig::default()
        };
        Setup { config, strings }
    }

    fn recommended(t: &Tree) -> Setup {
        Setup::new(
            &[&t.0],
            Some(&t.0),
            SLICK_FILES_RULES_RECOMMENDED | SLICK_FILES_RULES_ONE_FILESYSTEM,
        )
    }

    fn build(&self) -> Index {
        let mut ix = null_mut();
        let mut stats = SlickFilesWalkStats::default();
        let rc = slick_files_build(
            &self.config,
            self.strings.as_ptr(),
            self.strings.len(),
            &mut ix,
            &mut stats,
        );
        assert_eq!(rc, OK);
        assert!(stats.entries > 0 && stats.dirs > 0, "{stats:?}");
        Index(ix)
    }
}

struct Index(*mut SlickFiles);

impl Drop for Index {
    fn drop(&mut self) {
        assert_eq!(slick_files_free(self.0), OK);
    }
}

struct Session(*mut SlickFilesSession);

impl Session {
    fn new() -> Session {
        let mut s = null_mut();
        assert_eq!(slick_files_session_new(&mut s), OK);
        Session(s)
    }

    fn search_with(&self, ix: &Index, q: &str, o: &SlickFilesOptions) -> Vec<SlickFileHit> {
        let mut out = [SlickFileHit::default(); 50];
        let n = slick_files_search(ix.0, self.0, q.as_ptr(), q.len(), o, out.as_mut_ptr(), out.len());
        assert!(n >= 0, "status {n} for {q:?}");
        out[..n as usize].to_vec()
    }

    fn search(&self, ix: &Index, q: &str) -> Vec<SlickFileHit> {
        self.search_with(ix, q, &SlickFilesOptions::default())
    }

    fn path(&self, id: u32) -> String {
        let n = slick_files_session_path(self.0, id, null_mut(), 0);
        assert!(n > 0, "status {n}");
        let mut buf = vec![0u8; n as usize];
        assert_eq!(slick_files_session_path(self.0, id, buf.as_mut_ptr(), buf.len()), n);
        String::from_utf8(buf).expect("UTF-8 path")
    }

    /// Paths of the hits relative to `t`.
    fn names(&self, t: &Tree, hits: &[SlickFileHit]) -> Vec<String> {
        let root = format!("{}/", t.0.display());
        hits.iter()
            .map(|h| self.path(h.id).trim_start_matches(&root).to_string())
            .collect()
    }

    fn stats(&self) -> SlickFilesSearchStats {
        let mut st = SlickFilesSearchStats::default();
        assert_eq!(slick_files_session_stats(self.0, &mut st), OK);
        st
    }

    fn ranges(&self, hit: &SlickFileHit) -> Vec<SlickRange> {
        let mut out = [SlickRange::default(); 8];
        let n = slick_files_ranges(self.0, hit, out.as_mut_ptr(), out.len());
        assert!(n >= 0, "status {n}");
        out[..n as usize].to_vec()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        assert_eq!(slick_files_session_free(self.0), OK);
    }
}

fn synthetic(entries: u32, seed: u64) -> Index {
    let root = b"/synthetic/ffi-test";
    let mut ix = null_mut();
    assert_eq!(
        slick_files_synthetic(root.as_ptr(), root.len(), entries, seed, &mut ix),
        OK
    );
    Index(ix)
}

#[test]
fn layouts_are_fixed() {
    assert_eq!(size_of::<SlickFilesConfig>(), 48);
    assert_eq!(size_of::<SlickFilesWalkStats>(), 32);
    assert_eq!(size_of::<SlickFilesOpenInfo>(), 64);
    assert_eq!(size_of::<SlickFilesEvent>(), 16);
    assert_eq!(size_of::<SlickFilesUpdateStats>(), 48);
    assert_eq!(size_of::<SlickFilesOptions>(), 16);
    assert_eq!(size_of::<SlickFileHit>(), 12);
    assert_eq!(size_of::<SlickFileEntry>(), 24);
    assert_eq!(size_of::<SlickFilesInfo>(), 40);
    assert_eq!(size_of::<SlickFilesSearchStats>(), 16);
    use slick_files::{flags, rank::tier};
    assert_eq!(
        [
            SLICK_FILES_ENTRY_DIR,
            SLICK_FILES_ENTRY_PACKAGE,
            SLICK_FILES_ENTRY_HIDDEN,
            SLICK_FILES_ENTRY_SYMLINK,
            SLICK_FILES_ENTRY_ROOT,
            SLICK_FILES_ENTRY_UNREADABLE
        ],
        [
            flags::DIR,
            flags::PACKAGE,
            flags::HIDDEN,
            flags::SYMLINK,
            flags::ROOT,
            flags::UNREADABLE
        ]
    );
    assert_eq!(SLICK_FILES_NONE, slick_files::NONE);
    assert_eq!((tier::EXACT, tier::ANCESTOR), (7, 2));
    let hows = [
        slick_files::How::Name,
        slick_files::How::Ancestor,
        slick_files::How::Extension,
        slick_files::How::Typo,
        slick_files::How::Filter,
        slick_files::How::Browse,
    ];
    for (code, h) in hows.into_iter().enumerate() {
        assert_eq!(h as u8, code as u8);
    }
}

#[test]
fn build_search_paths_highlights_and_browse() {
    let t = Tree::home();
    let ix = Setup::recommended(&t).build();
    let s = Session::new();
    // The rules: no hidden names, no dependency folders, no Library, packages are leaves.
    for gone in ["secret", "index.js", "cache", "Info.plist"] {
        assert!(s.search(&ix, gone).is_empty(), "{gone} should not be indexed");
    }
    let tool = s.search(&ix, "tool");
    assert_eq!(s.names(&t, &tool), ["Tool.app"]);
    assert_eq!(tool[0].flags & SLICK_FILES_ENTRY_PACKAGE, SLICK_FILES_ENTRY_PACKAGE);
    // Names, folders, extensions and path fragments.
    let hits = s.search(&ix, "readme");
    let names = s.names(&t, &hits);
    assert!(names.contains(&"docs/readme.md".to_string()), "{names:?}");
    assert!(names.contains(&"projects/app/README.md".to_string()), "{names:?}");
    assert_eq!(s.ranges(&hits[0]), [SlickRange { start: 0, length: 6 }]);
    let hits = s.search(&ix, "docs readme");
    assert_eq!(s.names(&t, &hits)[0], "docs/readme.md");
    assert_eq!(hits[0].how, SLICK_FILES_HOW_ANCESTOR);
    let hits = s.search(&ix, ".pdf");
    assert_eq!(s.names(&t, &hits), ["docs/report 2024.pdf"]);
    assert_eq!(hits[0].how, SLICK_FILES_HOW_FILTER);
    assert_eq!(s.names(&t, &s.search(&ix, "src/main")), ["projects/app/src/main.rs"]);
    // Non-ASCII names fold, and highlights count UTF-16 units.
    let hits = s.search(&ix, "creme");
    assert_eq!(s.names(&t, &hits), ["café/crème brûlée.txt"]);
    assert_eq!(s.ranges(&hits[0]), [SlickRange { start: 0, length: 5 }]);
    // Kinds and a subtree.
    let folders = SlickFilesOptions {
        kinds: SLICK_FILES_KINDS_FOLDERS,
        ..SlickFilesOptions::default()
    };
    let hits = s.search_with(&ix, "app", &folders);
    assert!(!hits.is_empty() && hits.iter().all(|h| h.flags & SLICK_FILES_ENTRY_DIR != 0));
    let mut snap = null_mut();
    assert_eq!(slick_files_session_snapshot(s.0, &mut snap), OK);
    let docs = t.bytes("docs");
    let mut docs_id = 0;
    assert_eq!(
        slick_files_snapshot_lookup(snap, docs.as_ptr(), docs.len(), &mut docs_id),
        1
    );
    let inside = SlickFilesOptions {
        within: docs_id,
        ..SlickFilesOptions::default()
    };
    let n = s.names(&t, &s.search_with(&ix, "re", &inside));
    assert!(!n.is_empty() && n.iter().all(|p| p.starts_with("docs/")), "{n:?}");
    let missing = t.bytes("docs/nothing-here");
    let mut id = 7;
    assert_eq!(
        slick_files_snapshot_lookup(snap, missing.as_ptr(), missing.len(), &mut id),
        0
    );
    assert_eq!(id, SLICK_FILES_NONE);
    // Entry facts.
    let readme = s.search(&ix, "readme.md");
    let mut e = SlickFileEntry::default();
    assert_eq!(slick_files_session_entry(s.0, readme[0].id, &mut e), OK);
    assert_eq!((e.size, e.name_len, e.flags), (120, 9, 0));
    assert_eq!(slick_files_snapshot_entry(snap, docs_id, &mut e), OK);
    assert_eq!(
        (e.size, e.flags & SLICK_FILES_ENTRY_DIR),
        (u64::MAX, SLICK_FILES_ENTRY_DIR)
    );
    let mut info = SlickFilesInfo::default();
    assert_eq!(slick_files_snapshot_info(snap, &mut info), OK);
    assert_eq!(info.entries as i32, slick_files_count(ix.0));
    assert!(info.generation > 0 && info.slots >= info.entries);
    assert_eq!(slick_files_snapshot_free(snap), OK);
    // Browse: a leading ~ or / lists a folder.
    let home = t.bytes("");
    assert_eq!(slick_files_session_set_home(s.0, home.as_ptr(), home.len()), OK);
    let hits = s.search(&ix, "~/docs/");
    assert_eq!(hits.len(), 3);
    assert!(hits.iter().all(|h| h.how == SLICK_FILES_HOW_BROWSE));
    let typed = format!("{}/docs/re", t.0.display());
    let n = s.names(&t, &s.search(&ix, &typed));
    assert_eq!(n, ["docs/readme.md", "docs/report 2024.pdf"]);
    let by_time = SlickFilesOptions {
        browse_sort: SLICK_FILES_SORT_MODIFIED,
        ..SlickFilesOptions::default()
    };
    assert_eq!(s.search_with(&ix, "~/docs/", &by_time).len(), 3);
    let outside = s.search(&ix, "/nonexistent-folder/");
    assert!(outside.is_empty() && s.stats().not_indexed == 1);
    // Narrowing as the query grows.
    assert_eq!(slick_files_session_reset(s.0), OK);
    s.search(&ix, "m");
    assert_eq!(s.stats().narrowed, 0);
    s.search(&ix, "ma");
    s.search(&ix, "mai");
    assert_eq!(s.stats().narrowed, 1);
    assert_eq!(s.names(&t, &s.search(&ix, "main")), ["projects/app/src/main.rs"]);
}

#[test]
fn path_buffers_measure_and_refuse() {
    let t = Tree::home();
    let ix = Setup::recommended(&t).build();
    let s = Session::new();
    let mut buf = [0u8; 4];
    assert_eq!(
        slick_files_session_path(s.0, 0, buf.as_mut_ptr(), buf.len()),
        BAD,
        "no search yet"
    );
    let mut snap = null_mut();
    assert_eq!(slick_files_session_snapshot(s.0, &mut snap), BAD);
    let hits = s.search(&ix, "beach");
    let id = hits[0].id;
    let full = t.bytes("photos/beach.jpg");
    let n = slick_files_session_path(s.0, id, null_mut(), 0);
    assert_eq!(n as usize, full.len(), "cap 0 measures");
    assert_eq!(slick_files_session_path(s.0, id, buf.as_mut_ptr(), buf.len()), SMALL);
    let mut big = vec![0u8; 4096];
    let n = slick_files_session_path(s.0, id, big.as_mut_ptr(), big.len());
    assert_eq!(&big[..n as usize], &full[..]);
    for bad in [u32::MAX, u32::MAX - 1, 1 << 30] {
        assert_eq!(slick_files_session_path(s.0, bad, big.as_mut_ptr(), big.len()), BAD);
        let mut e = SlickFileEntry::default();
        assert_eq!(slick_files_session_entry(s.0, bad, &mut e), BAD);
    }
}

#[test]
fn events_save_open_and_snapshots_that_outlive_the_index() {
    let t = Tree::home();
    let store = Tree::new("store");
    let setup = Setup::recommended(&t);
    let ix = setup.build();
    let s = Session::new();
    let before = slick_files_count(ix.0);
    assert!(s.search(&ix, "agenda").is_empty());
    let mut old = null_mut();
    assert_eq!(slick_files_session_snapshot(s.0, &mut old), OK);
    // A file appears and its event arrives.
    let path = t.file("docs/agenda.txt", 3);
    let bytes = path.as_os_str().as_bytes().to_vec();
    let event = SlickFilesEvent {
        path_start: 0,
        path_len: bytes.len() as u32,
        flags: CREATED | IS_FILE,
        reserved: 0,
    };
    let mut st = SlickFilesUpdateStats::default();
    assert_eq!(
        slick_files_apply(ix.0, &event, 1, bytes.as_ptr(), bytes.len(), &mut st),
        OK
    );
    assert_eq!((st.events, st.added, st.published), (1, 1, 1), "{st:?}");
    assert_eq!(slick_files_count(ix.0), before + 1);
    let hits = s.search(&ix, "agenda");
    assert_eq!(s.names(&t, &hits), ["docs/agenda.txt"]);
    let mut id = 0;
    assert_eq!(
        slick_files_snapshot_lookup(old, bytes.as_ptr(), bytes.len(), &mut id),
        0
    );
    assert_eq!(slick_files_snapshot_free(old), OK);
    // Save, then open with the same settings: the file is used and the event id comes back.
    let file = store.bytes("files.idx");
    assert_eq!(slick_files_save(ix.0, file.as_ptr(), file.len(), 42), OK);
    let open = |setup: &Setup, file: &[u8]| -> (Index, SlickFilesOpenInfo) {
        let mut ix = null_mut();
        let mut info = SlickFilesOpenInfo::default();
        let c = &setup.config;
        let rc = slick_files_open_or_build(
            file.as_ptr(),
            file.len(),
            c,
            setup.strings.as_ptr(),
            setup.strings.len(),
            &mut ix,
            &mut info,
        );
        assert_eq!(rc, OK);
        (Index(ix), info)
    };
    let (reopened, info) = open(&setup, &file);
    assert_eq!(
        (info.opened, info.load_error, info.event_id),
        (1, SLICK_FILES_LOAD_OK, 42)
    );
    assert_eq!(info.entries as i32, before + 1);
    assert_eq!(s.names(&t, &s.search(&reopened, "agenda")), ["docs/agenda.txt"]);
    // Other settings, a missing file and a damaged file each build anew.
    let hidden = Setup::new(
        &[&t.0],
        Some(&t.0),
        SLICK_FILES_RULES_RECOMMENDED | SLICK_FILES_RULES_INCLUDE_HIDDEN,
    );
    let (other, info) = open(&hidden, &file);
    assert_eq!((info.opened, info.load_error), (0, SLICK_FILES_LOAD_MISMATCH));
    assert!(info.walk.entries > 0);
    assert_eq!(s.names(&t, &s.search(&other, "secret")), [".hidden/secret.txt"]);
    let (_, info) = open(&setup, &store.bytes("missing.idx"));
    assert_eq!(info.load_error, SLICK_FILES_LOAD_MISSING);
    fs::write(store.path("damaged.idx"), vec![7u8; 4096]).expect("write");
    let (_, info) = open(&setup, &store.bytes("damaged.idx"));
    assert_eq!(info.load_error, SLICK_FILES_LOAD_CORRUPT);
    let nowhere = b"/nonexistent-folder/files.idx";
    assert_eq!(slick_files_save(ix.0, nowhere.as_ptr(), nowhere.len(), 1), IO);
    // The file goes away.
    fs::remove_file(&path).expect("remove");
    let event = SlickFilesEvent {
        flags: REMOVED | IS_FILE,
        ..event
    };
    assert_eq!(
        slick_files_apply(ix.0, &event, 1, bytes.as_ptr(), bytes.len(), null_mut()),
        OK
    );
    assert!(s.search(&ix, "agenda").is_empty());
    let mut walked = SlickFilesWalkStats::default();
    assert_eq!(slick_files_rebuild(ix.0, &mut walked), OK);
    assert_eq!(slick_files_count(ix.0), before);
    // A snapshot and a session keep their data after the index is freed.
    let mut snap = null_mut();
    assert_eq!(slick_files_snapshot(reopened.0, &mut snap), OK);
    s.search(&reopened, "beach");
    drop(reopened);
    let beach = t.bytes("photos/beach.jpg");
    assert_eq!(
        slick_files_snapshot_lookup(snap, beach.as_ptr(), beach.len(), &mut id),
        1
    );
    let mut buf = vec![0u8; 4096];
    let n = slick_files_snapshot_path(snap, id, buf.as_mut_ptr(), buf.len());
    assert_eq!(&buf[..n as usize], &beach[..]);
    assert_eq!(
        s.names(
            &t,
            &[SlickFileHit {
                id,
                ..SlickFileHit::default()
            }]
        ),
        ["photos/beach.jpg"]
    );
    assert_eq!(slick_files_snapshot_free(snap), OK);
}

const QUERIES: &[&str] = &[
    "a",
    "re",
    "rea",
    "readme",
    "screenshot",
    "budget 2024",
    "docs readme",
    "report pdf",
    ".pdf",
    "src/main",
    "raedme",
    "zzqx",
    "meeting notes",
    "café",
];

#[test]
fn parallel_parts_equal_one_thread() {
    let ix = synthetic(60_000, 7);
    assert!(slick_files_count(ix.0) >= 60_000);
    let (serial, parallel) = (Session::new(), Session::new());
    let one = SlickFilesOptions {
        flags: SLICK_FILES_SEARCH_SERIAL,
        now: crate::synthetic::NOW,
        ..SlickFilesOptions::default()
    };
    let many = SlickFilesOptions { flags: 0, ..one };
    for q in QUERIES {
        let mut typed = String::new();
        for ch in q.chars() {
            typed.push(ch);
            let a = serial.search_with(&ix, &typed, &one);
            let b = parallel.search_with(&ix, &typed, &many);
            assert_eq!(a, b, "{typed:?}");
        }
        assert_eq!(slick_files_session_reset(serial.0), OK);
        assert_eq!(slick_files_session_reset(parallel.0), OK);
    }
    // Synthetic trees are deterministic per seed.
    let again = synthetic(60_000, 7);
    let other = Session::new();
    assert_eq!(
        serial.search_with(&ix, "budget", &one),
        other.search_with(&again, "budget", &one)
    );
}

#[test]
fn a_panic_in_a_part_reaches_the_calling_thread() {
    use slick_files::ParallelFor;
    let gcd = crate::files::Gcd { width: 4 };
    let hits = AtomicUsize::new(0);
    let r = std::panic::catch_unwind(|| {
        gcd.for_each(16, &|i| {
            hits.fetch_add(1, Ordering::Relaxed);
            assert!(i != 5, "part 5 fails");
        })
    });
    assert!(r.is_err());
    assert_eq!(hits.load(Ordering::Relaxed), 16, "the other parts still ran");
}

/// One typing session: every query typed char by char, through the C ABI.
fn type_queries(ix: &Index, s: &Session, o: &SlickFilesOptions, out: &mut [SlickFileHit]) -> usize {
    let mut found = 0;
    for q in QUERIES {
        assert_eq!(slick_files_session_reset(s.0), OK);
        for end in (1..=q.len()).filter(|&e| q.is_char_boundary(e)) {
            let n = slick_files_search(ix.0, s.0, q.as_ptr(), end, o, out.as_mut_ptr(), out.len());
            assert!(n >= 0);
            found += n as usize;
        }
    }
    found
}

/// The same typing session straight on `slick-files`, without the C ABI.
fn type_queries_direct(
    ix: &Index,
    searcher: &mut slick_files::Searcher,
    par: &dyn slick_files::ParallelFor,
    hits: &mut Vec<slick_files::FileHit>,
) -> usize {
    // SAFETY: `ix` owns a live index handle for the whole test.
    let snap = unsafe { &*ix.0 }.inner.snapshot();
    let opts = slick_files::SearchOptions {
        now: crate::synthetic::NOW,
        limit: 50,
        ..slick_files::SearchOptions::default()
    };
    let mut found = 0;
    for q in QUERIES {
        searcher.reset();
        for end in (1..=q.len()).filter(|&e| q.is_char_boundary(e)) {
            searcher.search(&snap, &q[..end], &opts, par, hits);
            found += hits.len();
        }
    }
    found
}

/// Allocations of five warm typing sessions through the C ABI and straight on the crate.
fn allocations(
    ix: &Index,
    o: &SlickFilesOptions,
    par: &dyn slick_files::ParallelFor,
    count: fn(&mut dyn FnMut()) -> usize,
) -> (usize, usize) {
    let s = Session::new();
    let mut out = [SlickFileHit::default(); 50];
    let mut direct = slick_files::Searcher::new();
    let mut hits = Vec::with_capacity(64);
    for _ in 0..3 {
        type_queries(ix, &s, o, &mut out);
        type_queries_direct(ix, &mut direct, par, &mut hits);
    }
    let (mut a, mut b) = (0, 0);
    let through_ffi = count(&mut || {
        for _ in 0..5 {
            a += type_queries(ix, &s, o, &mut out);
        }
    });
    let straight = count(&mut || {
        for _ in 0..5 {
            b += type_queries_direct(ix, &mut direct, par, &mut hits);
        }
    });
    assert_eq!(a, b, "the same hits both ways");
    (through_ffi, straight)
}

#[test]
fn the_c_abi_adds_no_allocations_to_a_warm_search() {
    let ix = synthetic(20_000, 3);
    let o = SlickFilesOptions {
        flags: SLICK_FILES_SEARCH_SERIAL,
        now: crate::synthetic::NOW,
        ..SlickFilesOptions::default()
    };
    let (ffi, straight) = allocations(&ix, &o, &slick_files::Serial, |f| alloc::on_this_thread(f));
    // slick-files itself allocates while it parses a query and merges parts; see the report.
    println!("one thread, five typing sessions: {ffi} allocations through the C ABI, {straight} straight");
    assert_eq!(ffi, straight, "the C ABI adds no allocations");
}

#[test]
fn the_c_abi_adds_no_allocations_to_a_warm_parallel_search() {
    alloc::in_child("tests::files::warm_parallel_search_child");
}

#[test]
#[ignore = "runs alone in a child process, see the_c_abi_adds_no_allocations_to_a_warm_parallel_search"]
fn warm_parallel_search_child() {
    assert!(std::env::var_os(alloc::CHILD).is_some(), "run through the parent test");
    let ix = synthetic(200_000, 5);
    let o = SlickFilesOptions {
        now: crate::synthetic::NOW,
        ..SlickFilesOptions::default()
    };
    let gcd = crate::files::Gcd {
        width: std::thread::available_parallelism().map_or(4, |n| n.get()),
    };
    let (ffi, straight) = allocations(&ix, &o, &gcd, |f| alloc::on_every_thread(f));
    println!("parallel, five typing sessions: {ffi} allocations through the C ABI, {straight} straight");
    // Parts race for the running threshold, so the crate's own count varies by a few either way.
    assert!(
        ffi <= straight + straight / 100,
        "the C ABI adds no allocations on any thread"
    );
}

#[test]
fn many_threads_search_while_the_index_changes() {
    let t = Tree::home();
    let ix = Setup::recommended(&t).build();
    let ptr = ix.0 as usize;
    std::thread::scope(|scope| {
        for k in 0..4 {
            scope.spawn(move || {
                let ix = ptr as *const SlickFiles;
                let s = Session::new();
                let mut out = [SlickFileHit::default(); 20];
                let o = SlickFilesOptions {
                    flags: if k % 2 == 0 { SLICK_FILES_SEARCH_SERIAL } else { 0 },
                    ..SlickFilesOptions::default()
                };
                for i in 0..300 {
                    let q = QUERIES[(i + k) % QUERIES.len()];
                    let n = slick_files_search(ix, s.0, q.as_ptr(), q.len(), &o, out.as_mut_ptr(), out.len());
                    assert!(n >= 0);
                    for h in &out[..n as usize] {
                        let len = slick_files_session_path(s.0, h.id, null_mut(), 0);
                        assert!(len > 0, "a hit resolves against its own snapshot");
                    }
                }
            });
        }
        scope.spawn(|| {
            let ix = ptr as *const SlickFiles;
            for i in 0..30 {
                let p = t.file(&format!("docs/churn-{i}.txt"), 1);
                let b = p.as_os_str().as_bytes();
                let e = SlickFilesEvent {
                    path_start: 0,
                    path_len: b.len() as u32,
                    flags: CREATED | IS_FILE,
                    reserved: 0,
                };
                assert_eq!(slick_files_apply(ix, &e, 1, b.as_ptr(), b.len(), null_mut()), OK);
                if i % 10 == 9 {
                    assert_eq!(slick_files_rebuild(ix, null_mut()), OK);
                }
            }
        });
    });
}

#[test]
fn hostile_arguments_come_back_as_statuses() {
    let t = Tree::home();
    let setup = Setup::recommended(&t);
    let ix = setup.build();
    let s = Session::new();
    let o = SlickFilesOptions::default();
    let mut out = [SlickFileHit::default(); 4];
    let q = b"readme";
    let dangling = std::ptr::NonNull::<u8>::dangling().as_ptr();
    // NULL handles, options and output slots.
    let search = |ix: *const SlickFiles, s: *mut SlickFilesSession, o: *const SlickFilesOptions| {
        slick_files_search(ix, s, q.as_ptr(), q.len(), o, out.as_ptr().cast_mut(), out.len())
    };
    assert_eq!(search(null(), s.0, &o), NULL);
    assert_eq!(search(ix.0, null_mut(), &o), NULL);
    assert_eq!(search(ix.0, s.0, null()), NULL);
    assert_eq!(slick_files_session_new(null_mut()), NULL);
    assert_eq!(slick_files_snapshot(ix.0, null_mut()), NULL);
    assert_eq!(slick_files_snapshot(null(), &mut null_mut()), NULL);
    assert_eq!(slick_files_count(null()), NULL);
    assert_eq!(slick_files_rebuild(null(), null_mut()), NULL);
    assert_eq!(slick_files_session_stats(s.0, null_mut()), NULL);
    assert_eq!(slick_files_ranges(s.0, null(), null_mut(), 0), NULL);
    let mut built = null_mut();
    let c = &setup.config;
    assert_eq!(
        slick_files_build(
            null(),
            setup.strings.as_ptr(),
            setup.strings.len(),
            &mut built,
            null_mut()
        ),
        NULL
    );
    assert_eq!(
        slick_files_build(c, setup.strings.as_ptr(), setup.strings.len(), null_mut(), null_mut()),
        NULL
    );
    for free in [
        slick_files_free(null_mut()),
        slick_files_session_free(null_mut()),
        slick_files_snapshot_free(null_mut()),
    ] {
        assert_eq!(free, OK);
    }
    // Options out of range, invalid UTF-8, impossible lengths, a misaligned hit buffer.
    for bad in [
        SlickFilesOptions { kinds: 3, ..o },
        SlickFilesOptions { prefer: 9, ..o },
        SlickFilesOptions { browse_sort: 2, ..o },
    ] {
        assert_eq!(search(ix.0, s.0, &bad), BAD, "{bad:?}");
    }
    let odd = SlickFilesOptions {
        within: 123_456,
        flags: 0xFF,
        now: u32::MAX,
        ..o
    };
    assert!(
        search(ix.0, s.0, &odd) >= 0,
        "unknown flags and a foreign folder find nothing harmful"
    );
    let rc = slick_files_search(ix.0, s.0, b"re\xff".as_ptr(), 3, &o, out.as_mut_ptr(), out.len());
    assert_eq!(rc, UTF8);
    let rc = slick_files_search(ix.0, s.0, dangling, usize::MAX, &o, out.as_mut_ptr(), out.len());
    assert_eq!(rc, BAD);
    let rc = slick_files_search(ix.0, s.0, q.as_ptr(), q.len(), &o, out.as_mut_ptr(), usize::MAX);
    assert_eq!(rc, BAD);
    let misaligned = unsafe_misaligned(&mut out);
    let rc = slick_files_search(ix.0, s.0, q.as_ptr(), q.len(), &o, misaligned, 2);
    assert_eq!(rc, BAD);
    let rc = slick_files_search(ix.0, s.0, q.as_ptr(), q.len(), &o, dangling.cast(), 0);
    assert_eq!(rc, 0, "no room");
    let rc = slick_files_search(ix.0, s.0, dangling, 0, &o, out.as_mut_ptr(), out.len());
    assert_eq!(rc, 0, "an empty query");
    // A hit that came from nowhere.
    let hit = SlickFileHit {
        id: u32::MAX,
        how: 77,
        ..SlickFileHit::default()
    };
    assert_eq!(slick_files_ranges(s.0, &hit, null_mut(), 0), BAD);
    let hit = SlickFileHit { how: 0, ..hit };
    assert_eq!(slick_files_ranges(s.0, &hit, null_mut(), 0), 0);
    // Configs: spans outside the buffer, relative roots, invalid UTF-8 in names.
    let strings = &setup.strings;
    let past = SlickFilesConfig {
        roots_len: strings.len() as u32 + 1,
        ..*c
    };
    let wrap = SlickFilesConfig {
        skip_names_start: u32::MAX,
        skip_names_len: u32::MAX,
        ..*c
    };
    for cfg in [past, wrap] {
        let rc = slick_files_build(&cfg, strings.as_ptr(), strings.len(), &mut built, null_mut());
        assert_eq!(rc, BAD, "{cfg:?}");
    }
    let relative = Setup::new(&[Path::new("relative/folder")], None, 0);
    let rc = slick_files_build(
        &relative.config,
        relative.strings.as_ptr(),
        relative.strings.len(),
        &mut built,
        null_mut(),
    );
    assert_eq!(rc, BAD);
    let mut bad_names = Setup::recommended(&t);
    let start = bad_names.strings.len() as u32;
    bad_names.strings.extend_from_slice(b"ok\0\xff\xfe");
    bad_names.config.leaf_extensions_start = start;
    bad_names.config.leaf_extensions_len = 5;
    let b = &bad_names;
    assert_eq!(
        slick_files_build(&b.config, b.strings.as_ptr(), b.strings.len(), &mut built, null_mut()),
        UTF8
    );
    assert!(built.is_null(), "nothing is stored on a refusal");
    // Events with spans outside the paths buffer change nothing.
    let paths = t.bytes("docs");
    let e = SlickFilesEvent {
        path_start: 1,
        path_len: paths.len() as u32,
        flags: CREATED,
        reserved: 0,
    };
    let before = slick_files_count(ix.0);
    assert_eq!(
        slick_files_apply(ix.0, &e, 1, paths.as_ptr(), paths.len(), null_mut()),
        BAD
    );
    assert_eq!(slick_files_apply(ix.0, dangling.cast(), 0, null(), 0, null_mut()), OK);
    assert_eq!(slick_files_count(ix.0), before);
    // Paths with NUL bytes or none at all are refused; so is a relative synthetic root.
    for p in [&b""[..], b"/tmp/a\0b"] {
        assert_eq!(slick_files_save(ix.0, p.as_ptr(), p.len(), 0), BAD);
        let rc = slick_files_open_or_build(
            p.as_ptr(),
            p.len(),
            c,
            strings.as_ptr(),
            strings.len(),
            &mut built,
            null_mut(),
        );
        assert_eq!(rc, BAD);
    }
    let mut syn = null_mut();
    assert_eq!(slick_files_synthetic(b"relative".as_ptr(), 8, 10, 1, &mut syn), BAD);
    assert_eq!(
        slick_files_session_set_home(s.0, b"\xff".as_ptr(), 1),
        OK,
        "home is bytes, like any path"
    );
}

/// A pointer one byte into `out`, so it is not aligned for `SlickFileHit`.
fn unsafe_misaligned(out: &mut [SlickFileHit]) -> *mut SlickFileHit {
    out.as_mut_ptr().cast::<u8>().wrapping_add(1).cast()
}
