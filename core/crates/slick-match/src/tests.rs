use super::*;
use crate::bits::{Bound, Sc};
use crate::rank::{FIELD_BONUS, MAX_QUALITY};
use crate::score::{PREFIX, WORD_PREFIX};

mod bounds;
mod corpus;

const TITLES: &[&str] = &[
    "Safari",
    "Safari Technology Preview",
    "1Password for Safari",
    "Visual Studio Code",
    "Xcode",
    "Codex",
    "Code Snippets",
    "System Settings",
    "SSH Settings",
    "Screen Sharing",
    "Screenshot",
    "Google Chrome",
    "Google Chat",
    "GarageBand",
    "Go to Calendar",
    "Terminal",
    "Terminal Notifier",
    "Terminology",
    "Thermal Monitor",
    "Text Terminator",
    "Toggle Dark Mode",
    "Dark Reader",
    "Calendar",
    "Calculator",
    "Café",
    "Café Finder",
    "Crème Brûlée Recipe",
    "微信",
    "网易云音乐",
    "日本語入力",
    "カレンダー",
    "🎉 Confetti",
    "😀 Emoji Picker",
    "Clipboard History",
    "Wi-Fi Settings",
    "Left Half",
    "Right Half",
    "GitHub: My Pull Requests",
    "Search Google",
    "Mission Control",
    "Music",
    "Messages",
    "Mail",
    "Maps",
];

fn arena() -> Arena {
    Arena::from_titles(TITLES.iter().copied())
}

fn run(a: &Arena, q: &str, lift: Option<&[i32]>) -> Vec<Hit> {
    let mut scratch = Scratch::default();
    let mut out = Vec::new();
    search(a, &Query::new(q), &Opts::default(), None, lift, &mut scratch, &mut out);
    out
}

fn top(a: &Arena, q: &str) -> Vec<&'static str> {
    run(a, q, None).into_iter().map(|h| TITLES[h.idx as usize]).collect()
}

fn rank_of(a: &Arena, q: &str, want: &str) -> Option<usize> {
    top(a, q).iter().position(|t| *t == want).map(|p| p + 1)
}

fn index_of(title: &str) -> usize {
    TITLES.iter().position(|t| *t == title).unwrap_or(usize::MAX)
}

#[test]
fn launcher_expectations() {
    let a = arena();
    assert_eq!(rank_of(&a, "saf", "Safari"), Some(1));
    assert_eq!(rank_of(&a, "vsc", "Visual Studio Code"), Some(1));
    assert_eq!(rank_of(&a, "vs code", "Visual Studio Code"), Some(1));
    assert!(rank_of(&a, "code", "Visual Studio Code").is_some_and(|r| r <= 3));
    assert!(rank_of(&a, "ss", "System Settings").is_some_and(|r| r <= 3));
    assert!(rank_of(&a, "gc", "Google Chrome").is_some_and(|r| r <= 3));
    assert_eq!(rank_of(&a, "sfari", "Safari"), Some(1));
    assert_eq!(rank_of(&a, "safaru", "Safari"), Some(1));
    assert_eq!(rank_of(&a, "termnial", "Terminal"), Some(1));
    assert_eq!(rank_of(&a, "term", "Terminal"), Some(1));
    let t = top(&a, "term");
    let thermal = t.iter().position(|x| *x == "Thermal Monitor");
    let text = t.iter().position(|x| *x == "Text Terminator");
    assert!(thermal.is_none() || thermal > text);
    assert!(rank_of(&a, "dark", "Toggle Dark Mode").is_some_and(|r| r <= 2));
    assert_eq!(rank_of(&a, "tdm", "Toggle Dark Mode"), Some(1));
    assert_eq!(rank_of(&a, "mode dark", "Toggle Dark Mode"), Some(1));
    assert_eq!(rank_of(&a, "cafe", "Café"), Some(1));
    assert_eq!(rank_of(&a, "café", "Café"), Some(1));
    assert_eq!(rank_of(&a, "creme brulee", "Crème Brûlée Recipe"), Some(1));
    assert_eq!(rank_of(&a, "微信", "微信"), Some(1));
    assert_eq!(rank_of(&a, "云音", "网易云音乐"), Some(1));
    assert_eq!(rank_of(&a, "カレ", "カレンダー"), Some(1));
    assert_eq!(rank_of(&a, "confetti", "🎉 Confetti"), Some(1));
    assert_eq!(rank_of(&a, "🎉", "🎉 Confetti"), Some(1));
    assert_eq!(rank_of(&a, "calendar", "Calendar"), Some(1));
    assert_eq!(rank_of(&a, "calender", "Calendar"), Some(1));
    assert_eq!(rank_of(&a, "musc", "Music"), Some(1));
    assert_eq!(rank_of(&a, "wifi", "Wi-Fi Settings"), Some(1));
    assert_eq!(rank_of(&a, "fari", "Safari"), Some(1));
    assert_eq!(rank_of(&a, "ghpr", "GitHub: My Pull Requests"), Some(1));
    assert_eq!(rank_of(&a, "m", "Mail"), Some(1)); // the shortest prefix wins ties
}

#[test]
fn an_exact_title_beats_any_lift() {
    let a = arena();
    let mut lift = vec![MAX_LIFT; a.len()];
    lift[index_of("Calendar")] = 0;
    assert_eq!(run(&a, "calendar", Some(&lift))[0].idx as usize, index_of("Calendar"));
}

#[test]
fn lift_reorders_inside_a_tier_and_never_across() {
    let a = arena();
    let mut lift = vec![0; a.len()];
    // Word-prefix "code" in Visual Studio Code stays under the prefix matches Codex and Code Snippets.
    lift[index_of("Visual Studio Code")] = MAX_LIFT;
    let hits = run(&a, "code", Some(&lift));
    let pos = |t: &str| hits.iter().position(|h| h.idx as usize == index_of(t));
    assert!(pos("Codex") < pos("Visual Studio Code"));
    // Among the two prefix matches, the lift decides.
    lift[index_of("Code Snippets")] = MAX_LIFT;
    let hits = run(&a, "code", Some(&lift));
    assert_eq!(hits[0].idx as usize, index_of("Code Snippets"));
}

#[test]
fn title_beats_alias_beats_keyword() {
    let mut a = Arena::new(false);
    a.push_item("Terminal Keeper", [], ["term"]);
    a.push_item("Shell", ["Term Two"], []);
    a.push_item("Terminal", [], []);
    let hits = run(&a, "term", None);
    let order: Vec<u32> = hits.iter().map(|h| h.idx).collect();
    assert_eq!(order, vec![2, 0, 1]);
    assert_eq!(hits[2].field, Field::Alias);
    // A keyword match ranks one tier below the same match on a title.
    let mut a = Arena::new(false);
    a.push_item("Network", [], ["wifi"]);
    a.push_item("Wifi Tools", [], []);
    let hits = run(&a, "wifi", None);
    assert_eq!(hits[0].idx, 1);
    assert_eq!((hits[1].field, hits[1].tier()), (Field::Keyword, PREFIX));
}

#[test]
fn every_match_string_maps_to_one_hit() {
    let mut a = Arena::new(false);
    a.push_item("Calendar", ["Calendar App", "Cal"], ["calendar events"]);
    let hits = run(&a, "cal", None);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].field, Field::Alias); // "cal" is an exact alias, stronger than a title prefix
}

#[test]
fn narrowing_equals_full_scan() {
    let a = arena();
    let mut session = Session::default();
    let mut inc = Vec::new();
    for q in [
        "s", "sa", "saf", "safa", "safar", "safari", "safar", "saf", "sy", "sys", "sys s", "sys", "",
    ] {
        let query = Query::new(q);
        session.search(&a, &query, &Opts::default(), None, &mut inc);
        let mut scratch = Scratch::default();
        let mut full = Vec::new();
        search(&a, &query, &Opts::default(), None, None, &mut scratch, &mut full);
        assert_eq!(full, inc, "query {q}");
    }
}

#[test]
fn ranges_are_utf16() {
    let titles = ["Café Finder", "🎉 Confetti", "Visual Studio Code", "Search GitHub"];
    let a = Arena::from_titles(titles.iter().copied());
    let mut scratch = HighlightScratch::default();
    let mut out = Vec::new();
    let mut check = |e: usize, q: &str, want: &[(u32, u32)]| {
        highlight::ranges(&a, e, &Query::new(q), titles[e], &mut scratch, &mut out);
        assert_eq!(out, want, "{q} in {}", titles[e]);
    };
    check(0, "cafe", &[(0, 4)]);
    // the emoji is 2 UTF-16 units plus a space, so "Conf" starts at 3
    check(1, "conf", &[(3, 4)]);
    check(1, "🎉", &[(0, 2)]);
    check(2, "vsc", &[(0, 1), (7, 1), (14, 1)]);
    check(3, "gh", &[(7, 1), (10, 1)]);
    check(2, "zzz", &[]);
}

#[test]
fn paths_score_the_basename_first() {
    let paths = [
        "/synthetic/Developer/readme-tool/src/main.rs",
        "/synthetic/Developer/project/README.md",
        "/synthetic/Documents/Notes/read me later.txt",
    ];
    let a = Arena::from_paths(paths.iter().copied());
    let mut scratch = Scratch::default();
    let mut hits = Vec::new();
    search(
        &a,
        &Query::new("readme"),
        &Opts::default(),
        None,
        None,
        &mut scratch,
        &mut hits,
    );
    assert_eq!(hits[0].idx, 1);
    let opts = Opts {
        path_fallback: true,
        ..Opts::default()
    };
    search(&a, &Query::new("readme"), &opts, None, None, &mut scratch, &mut hits);
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].idx, 1);
    let mut out = Vec::new();
    highlight::ranges(
        &a,
        1,
        &Query::new("readme"),
        paths[1],
        &mut HighlightScratch::default(),
        &mut out,
    );
    // "/synthetic/Developer/project/" is 29 UTF-16 units, so README starts at 29.
    assert_eq!(out, vec![(29, 6)]);
}

#[test]
fn one_char_fast_path_matches_general_path() {
    let corpus = corpus::titles(4_000, 11);
    let mut titles: Vec<&str> = TITLES.to_vec();
    titles.extend(corpus.iter().map(String::as_str));
    let a = Arena::from_titles(titles.iter().copied());
    for c in "abcdefghijklmnopqrstuvwxyz0123456789".chars() {
        let q = Query::new(&c.to_string());
        for e in 0..a.entries() {
            let w = a.window(e);
            if w.len() > 64 {
                continue;
            }
            let fast = score::score::<u8, false>(&q.needle(), w, a.ws[e], false, None);
            let mut pos = Vec::new();
            let general = score::score::<u8, true>(&q.needle(), w, a.ws[e], false, Some(&mut pos));
            assert_eq!(fast, general, "char {c} item {}", titles[e]);
        }
    }
}

/// Checks the NEON bit path against the scalar reference for every entry, every tier floor and a
/// set of rank bounds.
#[test]
fn bit_path_matches_scalar_reference() {
    let root = corpus::titles(4_000, 13);
    let files = corpus::paths(6_000, 14);
    let mut titles: Vec<&str> = TITLES.to_vec();
    titles.extend(root.iter().map(String::as_str));
    let paths: Vec<&str> = files.iter().map(String::as_str).collect();
    let queries = [
        "s",
        "sa",
        "saf",
        "ss",
        "te",
        "ter",
        "term",
        "vsc",
        "vs code",
        "mode dark",
        "tdm",
        "gc",
        "gh",
        "yt",
        "fari",
        "sfari",
        "ghpr",
        "wifi",
        "wi fi",
        "dark",
        "e",
        "x",
        "main.rs",
        "readme",
        "scr 2024",
        "img_48",
        "a b",
        "toggle dark mode",
        "clip hist",
        "search goo",
        "half left",
        "pdf",
        "lib.rs",
        ".",
        "-",
        "s s",
        "aaa",
        "zz",
        "visual studio code",
    ];
    let mut keyword_arena = Arena::new(false);
    for t in titles.iter().take(2_000) {
        keyword_arena.push_item("x", [], [*t]);
    }
    for (arena, label) in [
        (Arena::from_titles(titles.iter().copied()), "titles"),
        (Arena::from_paths(paths.iter().copied()), "paths"),
        (keyword_arena, "keywords"),
    ] {
        let mut checked = 0;
        for qs in queries {
            let q = Query::new(qs);
            let nd = q.needle();
            for e in 0..arena.entries() {
                let st = arena.start[e] as usize + arena.win[e] as usize;
                let w = arena.window(e);
                if w.is_empty() || w.len() > 64 {
                    continue;
                }
                let field = arena.field(e);
                let block: &[u8; 64] = arena.text[st..st + 64].try_into().expect("padded arena");
                let reference = score::score::<u8, false>(&nd, w, arena.ws[e], false, None);
                for floor in 0u8..=7 {
                    let got = bits::score_bits(&nd, &q.bn, block, w.len(), arena.ws[e], floor, Bound::NONE);
                    match (reference, got) {
                        (None, Sc::No) => {}
                        (Some(t), Sc::Yes(g)) if t == g && (t.tier >= floor || t.tier == score::EXACT) => {}
                        (Some(t), Sc::Below) if t.tier < floor => {}
                        (r, _) => panic!(
                            "{label} q={qs:?} floor={floor} item={:?} ref={r:?}",
                            String::from_utf8_lossy(w)
                        ),
                    }
                }
                // Rank-level bound: Below only when the true rank is under the threshold.
                for (thresh, lift) in [
                    (52_000, 0),
                    (53_850, 0),
                    (53_850, 4_000),
                    (56_200, 2_000),
                    (40_000, MAX_LIFT),
                ] {
                    let floor = rank::floor_tier(thresh, field, lift);
                    let bound = Bound {
                        thresh,
                        word_prefix_base: rank::word_prefix_base(field, lift),
                    };
                    let got = bits::score_bits(&nd, &q.bn, block, w.len(), arena.ws[e], floor, bound);
                    let true_rank = reference.and_then(|t| rank::rank(t, field, lift));
                    match (reference, got) {
                        (None, Sc::No) => {}
                        (Some(t), Sc::Yes(g)) if t == g => {}
                        (Some(_), Sc::Below) if true_rank.is_none_or(|r| r < thresh) => {}
                        (r, _) => panic!(
                            "{label} q={qs:?} thresh={thresh} item={:?} ref={r:?}",
                            String::from_utf8_lossy(w)
                        ),
                    }
                }
                checked += 1;
            }
        }
        assert!(checked > 1000, "{label}: {checked}");
    }
}

#[test]
fn word_prefix_bound_covers_the_best_word_prefix_quality() {
    // The bit path assumes no word-prefix match beats 940 - 40*fw - 3*extra.
    let corpus = corpus::titles(3_000, 21);
    let a = Arena::from_titles(corpus.iter().map(String::as_str));
    for qs in ["gh", "tdm", "code", "dark", "sw", "ms", "cv", "ab"] {
        let q = Query::new(qs);
        for e in 0..a.entries() {
            if let Some(t) = score::score::<u8, false>(&q.needle(), a.window(e), a.ws[e], false, None)
                && t.tier == WORD_PREFIX
            {
                assert!(
                    t.quality as i32 <= 940,
                    "{qs} {:?}",
                    String::from_utf8_lossy(a.window(e))
                );
            }
        }
    }
    assert_eq!(FIELD_BONUS[0] + MAX_QUALITY + MAX_LIFT, TIER_GAP - 1);
}
