//! What people expect from file search, on a small fixed tree.

use slick_files::{
    BrowseSort, Builder, EntryId, FileHit, How, Kinds, Prefer, SearchOptions, Searcher, Serial, Snapshot, flags,
};
use std::sync::Arc;

const NOW: u32 = 1_700_000_000;
const DAY: u32 = 86_400;

struct Fixture {
    snap: Arc<Snapshot>,
    ids: std::collections::HashMap<&'static str, EntryId>,
}

fn fixture() -> Fixture {
    let mut b = Builder::new();
    let mut ids = std::collections::HashMap::new();
    let root = b.root(b"/home/someone", NOW);
    ids.insert("", root);
    let add = |b: &mut Builder,
               ids: &mut std::collections::HashMap<&'static str, EntryId>,
               parent: &str,
               name: &'static str,
               f: u8,
               age_days: u32| {
        let p = ids[parent];
        let id = b.add(p, name.as_bytes(), f, NOW - age_days * DAY, 100);
        ids.insert(name, id);
    };
    add(&mut b, &mut ids, "", "docs", flags::DIR, 3);
    add(&mut b, &mut ids, "docs", "README.md", 0, 3);
    add(&mut b, &mut ids, "docs", "guide.pdf", 0, 40);
    add(&mut b, &mut ids, "", "projects", flags::DIR, 1);
    add(&mut b, &mut ids, "projects", "launcher", flags::DIR, 1);
    add(&mut b, &mut ids, "launcher", "src", flags::DIR, 1);
    add(&mut b, &mut ids, "src", "main.rs", 0, 1);
    add(&mut b, &mut ids, "src", "readme_old_scans.txt", 0, 900);
    add(&mut b, &mut ids, "", "Reports", flags::DIR, 10);
    add(&mut b, &mut ids, "Reports", "report-q3.pdf", 0, 10);
    add(&mut b, &mut ids, "Reports", "report-q3.docx", 0, 10);
    add(&mut b, &mut ids, "Reports", "Quarterly report.pdf", 0, 2_000);
    add(&mut b, &mut ids, "", "Editor.app", flags::DIR | flags::PACKAGE, 30);
    add(&mut b, &mut ids, "", ".zshrc", flags::HIDDEN, 30);
    add(&mut b, &mut ids, "", "readme", flags::DIR, 4_000);
    Fixture {
        snap: Arc::new(b.finish()),
        ids,
    }
}

fn opts() -> SearchOptions {
    SearchOptions {
        now: NOW,
        home: Some(b"/home/someone".to_vec()),
        ..SearchOptions::default()
    }
}

fn names(f: &Fixture, hits: &[FileHit]) -> Vec<String> {
    hits.iter()
        .map(|h| String::from_utf8_lossy(f.snap.entry(h.id).map_or(&b"?"[..], |e| e.name)).into_owned())
        .collect()
}

fn search(f: &Fixture, q: &str, o: &SearchOptions) -> Vec<FileHit> {
    let mut s = Searcher::new();
    let mut out = Vec::new();
    s.search(&f.snap, q, o, &Serial, &mut out);
    out
}

#[test]
fn folder_tokens_find_a_readme_inside_docs() {
    let f = fixture();
    let hits = search(&f, "docs readme", &opts());
    assert_eq!(names(&f, &hits).first().map(String::as_str), Some("README.md"));
    assert_eq!(hits[0].how, How::Ancestor);
    // The other order works too.
    let hits = search(&f, "readme docs", &opts());
    assert_eq!(names(&f, &hits).first().map(String::as_str), Some("README.md"));
}

#[test]
fn path_fragments() {
    let f = fixture();
    let hits = search(&f, "launcher/src main", &opts());
    assert_eq!(names(&f, &hits), vec!["main.rs"]);
    let hits = search(&f, "proj/launch/src main", &opts());
    assert_eq!(names(&f, &hits), vec!["main.rs"]);
    // The parts of a fragment are consecutive folders; a space allows gaps.
    assert!(search(&f, "proj/src main", &opts()).is_empty());
    let hits = search(&f, "proj main", &opts());
    assert_eq!(names(&f, &hits), vec!["main.rs"]);
    let hits = search(&f, "src/main", &opts());
    assert_eq!(names(&f, &hits), vec!["main.rs"]);
    let hits = search(&f, "launcher/", &opts());
    assert_eq!(
        names(&f, &hits).first().map(String::as_str),
        Some("src"),
        "shallow first"
    );
    assert_eq!(hits.len(), 3);
}

#[test]
fn extensions() {
    let f = fixture();
    let hits = search(&f, "report pdf", &opts());
    let n = names(&f, &hits);
    assert_eq!(n[0], "report-q3.pdf");
    assert!(!n.contains(&"report-q3.docx".to_string()));
    let hits = search(&f, ".pdf", &opts());
    let mut n = names(&f, &hits);
    n.sort();
    assert_eq!(n, vec!["Quarterly report.pdf", "guide.pdf", "report-q3.pdf"]);
    let hits = search(&f, "report .docx", &opts());
    assert_eq!(names(&f, &hits), vec!["report-q3.docx"]);
}

#[test]
fn ranking_inside_a_tier_prefers_new_shallow_and_the_chosen_kind() {
    let f = fixture();
    // "readme" exactly names an old, shallow folder and prefixes a new, deeper file.
    let mut o = opts();
    let hits = search(&f, "readme", &o);
    assert_eq!(names(&f, &hits)[0], "readme", "exact beats prefix whatever the lift");
    o.prefer = Prefer::Files;
    let hits = search(&f, "readm", &o);
    assert_eq!(names(&f, &hits)[0], "README.md");
    // Within one tier, the newer of two equal names wins.
    let hits = search(&f, "report q3", &opts());
    assert!(names(&f, &hits)[..2].contains(&"report-q3.pdf".to_string()));
}

#[test]
fn subtree_and_kind_filters() {
    let f = fixture();
    let mut o = opts();
    o.within = Some(f.ids["Reports"]);
    let n = names(&f, &search(&f, "r", &o));
    assert!(n.iter().all(|x| x.contains("report") || x.contains("Report")), "{n:?}");
    assert!(
        !n.contains(&"Reports".to_string()),
        "the folder itself is not inside itself"
    );
    o.within = None;
    o.kinds = Kinds::Folders;
    let n = names(&f, &search(&f, "r", &o));
    assert!(
        n.iter()
            .all(|x| f.snap.entry(f.ids[x.as_str()]).is_some_and(|e| e.is_dir())),
        "{n:?}"
    );
    assert_eq!(n.len(), 6);
    o.kinds = Kinds::Files;
    assert!(!names(&f, &search(&f, "readme", &o)).contains(&"readme".to_string()));
}

#[test]
fn hidden_entries_need_the_option() {
    let f = fixture();
    assert!(search(&f, "zshrc", &opts()).is_empty());
    let mut o = opts();
    o.include_hidden = true;
    assert_eq!(names(&f, &search(&f, "zshrc", &o)), vec![".zshrc"]);
}

#[test]
fn typos_are_found_when_nothing_matches_well() {
    let f = fixture();
    let hits = search(&f, "raedme", &opts());
    assert!(
        names(&f, &hits).iter().any(|n| n.eq_ignore_ascii_case("readme.md")),
        "{:?}",
        names(&f, &hits)
    );
    let hits = search(&f, "gudie", &opts());
    assert_eq!(names(&f, &hits).first().map(String::as_str), Some("guide.pdf"));
}

#[test]
fn browsing_folders() {
    let f = fixture();
    let n = names(&f, &search(&f, "~/", &opts()));
    assert_eq!(n, vec!["docs", "Editor.app", "projects", "readme", "Reports"]);
    let n = names(&f, &search(&f, "~/rep", &opts()));
    assert_eq!(n, vec!["Reports"]);
    let n = names(&f, &search(&f, "/home/someone/Reports/", &opts()));
    assert_eq!(n, vec!["Quarterly report.pdf", "report-q3.docx", "report-q3.pdf"]);
    let mut o = opts();
    o.browse_sort = BrowseSort::Modified;
    let n = names(&f, &search(&f, "/home/someone/reports/", &o));
    assert_eq!(
        n.last().map(String::as_str),
        Some("Quarterly report.pdf"),
        "case-blind path, oldest last"
    );
    let n = names(&f, &search(&f, "~/.z", &opts()));
    assert_eq!(n, vec![".zshrc"], "a dot filter shows hidden names");
    let mut s = Searcher::new();
    let mut out = Vec::new();
    s.search(&f.snap, "/usr/local/", &opts(), &Serial, &mut out);
    assert!(out.is_empty() && s.stats().not_indexed);
}

#[test]
fn highlights_are_utf16_ranges_of_the_name() {
    let f = fixture();
    let mut s = Searcher::new();
    let mut out = Vec::new();
    let o = opts();
    let mut ranges = Vec::new();
    s.search(&f.snap, "docs readme", &o, &Serial, &mut out);
    s.highlight(&out[0], "docs readme", &o, &mut ranges);
    assert_eq!(ranges, vec![(0, 6)]);
    s.search(&f.snap, "rq3", &o, &Serial, &mut out);
    s.highlight(&out[0], "rq3", &o, &mut ranges);
    assert!(!ranges.is_empty());
    s.search(&f.snap, "report pdf", &o, &Serial, &mut out);
    s.highlight(&out[0], "report pdf", &o, &mut ranges);
    assert_eq!(ranges.first(), Some(&(0, 6)));
}

#[test]
fn paths_rebuild_from_parents() {
    let f = fixture();
    let id = f.ids["main.rs"];
    assert_eq!(
        f.snap.path(id).as_deref(),
        Some(&b"/home/someone/projects/launcher/src/main.rs"[..])
    );
    let mut buf = [0u8; 64];
    let n = f.snap.path_to_slice(id, &mut buf).expect("fits");
    assert_eq!(&buf[..n], b"/home/someone/projects/launcher/src/main.rs");
    assert_eq!(f.snap.path_to_slice(id, &mut buf[..8]), Err(n));
}

#[test]
fn a_decomposed_name_ranks_and_highlights_like_a_composed_one() {
    let composed_name = "crème brûlée.txt";
    let decomposed_name = "cre\u{300}me bru\u{302}le\u{301}e.txt";
    for (name, range) in [(composed_name, (0, 5)), (decomposed_name, (0, 6))] {
        let mut b = Builder::new();
        let root = b.root(b"/home/someone", NOW);
        let id = b.add(root, name.as_bytes(), 0, NOW - DAY, 10);
        let snap = Arc::new(b.finish());
        let mut s = Searcher::new();
        let mut out = Vec::new();
        let o = opts();
        s.search(&snap, "creme", &o, &Serial, &mut out);
        assert_eq!(out.len(), 1, "{name:?}");
        assert_eq!(out[0].id, id);
        assert_eq!(
            out[0].tier(),
            slick_files::rank::tier::PREFIX,
            "{name:?} matches at prefix"
        );
        let mut ranges = Vec::new();
        s.highlight(&out[0], "creme", &o, &mut ranges);
        assert_eq!(ranges, vec![range], "{name:?}: the range covers the combining mark");
        // Typed char by char, narrowing keeps the match.
        s.reset();
        for q in ["c", "cr", "cre", "crem", "creme", "creme b", "creme bru"] {
            s.search(&snap, q, &o, &Serial, &mut out);
            assert_eq!(out.first().map(|h| h.id), Some(id), "{name:?} for {q:?}");
        }
        // A decomposed query finds both.
        s.reset();
        s.search(&snap, "cre\u{300}me", &o, &Serial, &mut out);
        assert_eq!(out.first().map(|h| h.id), Some(id));
    }
}
