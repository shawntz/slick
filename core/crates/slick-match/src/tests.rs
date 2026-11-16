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

fn run_whole(a: &Arena, q: &str, lift: Option<&[i32]>) -> Vec<Hit> {
    let mut scratch = Scratch::default();
    let mut out = Vec::new();
    let query = Query::with_whole_words(q);
    search(a, &query, &Opts::default(), None, lift, &mut scratch, &mut out);
    out
}

fn tier_in(hits: &[Hit], title: &str) -> Option<u8> {
    hits.iter().find(|h| h.idx as usize == index_of(title)).map(Hit::tier)
}

fn titles_of(hits: &[Hit]) -> Vec<&'static str> {
    hits.iter().map(|h| TITLES[h.idx as usize]).collect()
}

#[test]
fn a_whole_later_word_ranks_with_literal_prefixes() {
    let a = arena();
    // Off, as file search runs: "code" in Visual Studio Code is a word-prefix match.
    assert_eq!(tier_in(&run(&a, "code", None), "Visual Studio Code"), Some(WORD_PREFIX));
    // On, as root search runs: it joins the literal prefixes, which stay ahead on text alone
    // because they are shorter or put the word first.
    let hits = run_whole(&a, "code", None);
    assert_eq!(tier_in(&hits, "Visual Studio Code"), Some(PREFIX));
    assert_eq!(titles_of(&hits)[..3], ["Codex", "Code Snippets", "Visual Studio Code"]);
    assert_eq!(
        tier_in(&hits, "Xcode"),
        Some(score::SUBSTRING),
        "mid-word stays a substring"
    );
    // A prior inside the tier now decides, as the app prior does in the engine.
    let mut lift = vec![0; a.len()];
    lift[index_of("Visual Studio Code")] = 600;
    assert_eq!(titles_of(&run_whole(&a, "code", Some(&lift)))[0], "Visual Studio Code");
    let hits = run_whole(&a, "chrome", None);
    assert_eq!((titles_of(&hits)[0], hits[0].tier()), ("Google Chrome", PREFIX));
    // Earlier words and shorter titles rank higher inside the tier.
    assert_eq!(
        titles_of(&run_whole(&a, "google", None)),
        ["Google Chat", "Google Chrome", "Search Google"]
    );
    assert_eq!(tier_in(&run_whole(&a, "google", None), "Search Google"), Some(PREFIX));
}

#[test]
fn only_a_whole_word_of_a_one_token_query_is_promoted() {
    let tier = |q: &str, title: &str| {
        let query = Query::with_whole_words(q);
        let (bytes, ws) = {
            let (f, _) = fold::fold_str(title, 0);
            (f.bytes, f.ws)
        };
        score::score::<u8, false>(&query.needle(), &bytes, ws, false, None)
    };
    let prefix = |q: &str, title: &str| tier(q, title).map(|t| t.tier);
    assert_eq!(
        tier("code", "Visual Studio Code"),
        Some(TextScore::new(PREFIX, score::whole_word_quality(18, 4, 2)))
    );
    assert_eq!(prefix("cod", "Visual Studio Code"), Some(WORD_PREFIX), "part of a word");
    assert_eq!(
        prefix("studio code", "Visual Studio Code"),
        Some(WORD_PREFIX),
        "two tokens"
    );
    assert_eq!(prefix("c", "Visual Studio Code"), Some(WORD_PREFIX), "one char");
    assert_eq!(prefix("codes", "Visual Studio Code"), None);
    // A camelCase hump is a word, and a word may end at the next hump or a separator.
    assert_eq!(prefix("time", "QuickTime Player"), Some(PREFIX));
    assert_eq!(prefix("quick", "Open QuickTime"), Some(PREFIX));
    assert_eq!(prefix("fi", "Toggle Wi-Fi"), Some(PREFIX));
    // A word that only starts with the query is not whole.
    assert_eq!(prefix("quic", "Open QuickTime"), Some(WORD_PREFIX));
    // The first whole word counts, even when the segmentation finds a scattered path first.
    assert_eq!(
        tier("code", "Copy Old Data Encoder Code"),
        Some(TextScore::new(PREFIX, score::whole_word_quality(26, 4, 4)))
    );
    // Ideographs each start a word, so a run of them is never one whole word.
    let a = Arena::from_titles(["网易云音乐"]);
    assert_eq!(run_whole(&a, "云音", None)[0].tier(), WORD_PREFIX);
    // Non-ASCII letters with spaces between words are promoted on the char path.
    let a = Arena::from_titles(["Ζ Δέλτα", "Δέλτα Ωμέγα Λάμδα"]);
    let hits = run_whole(&a, "δέλτα", None);
    assert_eq!(hits.iter().map(Hit::tier).collect::<Vec<_>>(), [PREFIX, PREFIX]);
}

/// The span mask the bound reads must hold every whole word the scorer promotes, or the bound
/// would skip a title that ranks in the prefix tier.
#[test]
fn the_span_mask_holds_every_promoted_word() {
    let spans = |s: &str| {
        let (f, _) = fold::fold_str(s, 0);
        arena::span_mask(&f.bytes, f.ws)
    };
    let bit = |w: &str| Query::new(w).span;
    let github = spans("Search GitHub");
    for w in ["search", "git", "hub", "github"] {
        assert_ne!(github & bit(w), 0, "{w}");
    }
    // A query with a separator does not use the mask.
    assert_eq!(bit("wi-fi"), 0);
    assert_eq!(bit("x"), 0);
    let corpus = corpus::titles(4_000, 17);
    let mut titles: Vec<&str> = TITLES.to_vec();
    titles.extend(corpus.iter().map(String::as_str));
    let a = Arena::from_titles(titles.iter().copied());
    let mut promoted = 0;
    for (e, title) in titles.iter().enumerate() {
        // Every word and every camelCase part of the title, typed whole.
        let lower = title.to_lowercase();
        let mut words: Vec<&str> = lower.split(|c: char| !c.is_ascii_alphanumeric()).collect();
        words.extend(["code", "hub", "time", "settings"]);
        for w in words.into_iter().filter(|w| w.len() >= 2) {
            let on = Query::with_whole_words(w);
            let off = Query::new(w);
            let window = a.window(e);
            let with = score::score::<u8, false>(&on.needle(), window, a.ws[e], false, None);
            let without = score::score::<u8, false>(&off.needle(), window, a.ws[e], false, None);
            if with != without {
                promoted += 1;
                assert_ne!(a.spans[e] & on.span, 0, "{w:?} in {title:?}");
            }
        }
    }
    assert!(promoted > 1_000, "{promoted}");
}

#[test]
fn a_promoted_word_highlights_the_word() {
    let titles = ["Visual Studio Code", "Copy Old Data Encoder Code", "Open QuickTime"];
    let a = Arena::from_titles(titles);
    let mut scratch = HighlightScratch::default();
    let mut out = Vec::new();
    for (e, q, want) in [(0, "code", (14, 4)), (1, "code", (22, 4)), (2, "time", (10, 4))] {
        highlight::ranges(&a, e, &Query::with_whole_words(q), titles[e], &mut scratch, &mut out);
        assert_eq!(out, [want], "{q} in {}", titles[e]);
    }
    // Off, the segmentation's own path is highlighted.
    highlight::ranges(&a, 1, &Query::new("code"), titles[1], &mut scratch, &mut out);
    assert_eq!(out, [(0, 1), (5, 1), (9, 1), (14, 1)]);
}

/// Once the threshold is in the unordered tier, a title none of whose words starts with the
/// query's first char is skipped with one load. It must never be one that could rank, and it
/// stays in the narrowing set.
#[test]
fn a_title_without_the_first_char_at_a_word_start_is_skipped_only_when_it_cannot_rank() {
    let mut titles: Vec<String> = (0..60).map(|i| format!("Safe Mode {i}")).collect();
    titles.extend(["Mesa", "Visa Tools", "Sa"].map(String::from));
    let a = Arena::from_titles(titles.iter().map(String::as_str));
    let mesa = 60;
    // The highest lift there is, on the title whose s is mid-word.
    let mut lift = vec![0; a.len()];
    lift[mesa] = MAX_LIFT;
    let best_substring = rank::rank(TextScore::new(score::SUBSTRING, 999), Field::Title, MAX_LIFT);
    assert!(best_substring.is_some_and(|r| r < rank::TIER_GAP * score::UNORDERED as i32));
    for (q, k) in [("sa", 50), ("sa", 70), ("s", 50), ("sm", 10), ("vt", 1), ("es", 50)] {
        for whole in [false, true] {
            let query = if whole {
                Query::with_whole_words(q)
            } else {
                Query::new(q)
            };
            let opts = Opts { k, ..Opts::default() };
            let unbounded = Opts { bound: false, ..opts };
            let (mut s1, mut s2) = (Scratch::default(), Scratch::default());
            let (mut bounded_hits, mut all_hits) = (Vec::new(), Vec::new());
            search(&a, &query, &opts, None, Some(&lift), &mut s1, &mut bounded_hits);
            search(&a, &query, &unbounded, None, Some(&lift), &mut s2, &mut all_hits);
            assert_eq!(bounded_hits, all_hits, "{q} k {k} whole {whole}");
            if s2.matched.contains(&(mesa as u32)) {
                assert!(
                    s1.matched.contains(&(mesa as u32)),
                    "{q} k {k}: Mesa left the narrowing set"
                );
            }
        }
    }
    // With room for every match, Mesa ranks after the exact title and the 60 prefix matches.
    let mut hits = Vec::new();
    let opts = Opts {
        k: 100,
        ..Opts::default()
    };
    search(
        &a,
        &Query::new("sa"),
        &opts,
        None,
        Some(&lift),
        &mut Scratch::default(),
        &mut hits,
    );
    assert_eq!(hits.iter().position(|h| h.idx as usize == mesa), Some(61));
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
        "code",
        "chrome",
        "studio",
        "half",
        "hub",
        "settings",
        "rs",
        "md",
        "notes",
        "in",
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
        for (qs, whole) in queries.iter().flat_map(|&qs| [(qs, false), (qs, true)]) {
            let q = if whole {
                Query::with_whole_words(qs)
            } else {
                Query::new(qs)
            };
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
                            "{label} q={qs:?} whole={whole} floor={floor} item={:?} ref={r:?}",
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
                            "{label} q={qs:?} whole={whole} thresh={thresh} item={:?} ref={r:?}",
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

/// Decomposed text: a base char and its combining marks, as Foundation's file URLs and older Mac
/// volumes store names.
const NFD_SAMPLES: &[(&str, &str)] = &[
    ("Cre\u{300}me Bru\u{302}le\u{301}e Recipe", "Crème Brûlée Recipe"),
    ("Cafe\u{301}", "Café"),
    ("A\u{30a}lesund", "Ålesund"),
    ("U\u{308}bersicht", "Übersicht"),
    ("\u{304b}\u{3099}\u{304f}\u{3099}", "\u{304c}\u{3050}"),
    ("\u{1100}\u{1161}\u{11a8} note", "\u{ac01} note"),
    ("\u{438}\u{306} file", "\u{439} file"),
    ("x\u{301}y", "xy"),
    ("1\u{fe0f}\u{20e3} plan", "1 plan"),
];

#[test]
fn decomposed_text_folds_like_composed_text() {
    for &(nfd, nfc) in NFD_SAMPLES {
        let (d, _) = fold::fold_str(nfd, 0);
        let (c, _) = fold::fold_str(nfc, 0);
        assert_eq!(
            (&d.bytes, d.ws, d.mask, d.initials, d.initials2),
            (&c.bytes, c.ws, c.mask, c.initials, c.initials2),
            "{nfd:?}"
        );
        assert!(!d.one_to_one, "{nfd:?}: composing changes the char count");
        assert_eq!(Query::new(nfd).full, Query::new(nfc).full, "{nfd:?} as a query");
        let mut chars: Vec<char> = nfd.chars().collect();
        fold::compose_in_place(&mut chars);
        let glyphs: Vec<char> = fold::composed(nfd.chars()).map(|g| g.c).collect();
        assert_eq!(chars, glyphs, "{nfd:?}: both ways compose alike");
        let units: u32 = fold::composed(nfd.chars()).map(|g| g.units).sum();
        assert_eq!(units as usize, nfd.encode_utf16().count());
        let bytes: u32 = fold::composed(nfd.chars()).map(|g| g.bytes).sum();
        assert_eq!(bytes as usize, nfd.len());
    }
    // Composed text is left alone.
    let (plain, _) = fold::fold_str("Crème Brûlée Recipe", 0);
    assert_eq!(plain.bytes, b"creme brulee recipe");
}

#[test]
fn decomposed_titles_match_and_highlight_like_composed_ones() {
    let titles = ["Cre\u{300}me Bru\u{302}le\u{301}e Recipe", "Crème Brûlée Recipe"];
    let a = Arena::from_titles(titles);
    let q = Query::new("creme");
    let hits = run(&a, "creme", None);
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].tier(), hits[1].tier(), "the same tier both ways");
    assert_eq!(hits[0].tier(), PREFIX);
    let mut scratch = HighlightScratch::default();
    let mut out = Vec::new();
    highlight::ranges(&a, 0, &q, titles[0], &mut scratch, &mut out);
    assert_eq!(out, vec![(0, 6)], "the range covers the combining mark");
    highlight::ranges(&a, 1, &q, titles[1], &mut scratch, &mut out);
    assert_eq!(out, vec![(0, 5)]);
    let q = Query::new("brulee");
    highlight::ranges(&a, 0, &q, titles[0], &mut scratch, &mut out);
    assert_eq!(out, vec![(7, 8)], "both marks inside the word are covered");
    highlight::ranges(&a, 1, &q, titles[1], &mut scratch, &mut out);
    assert_eq!(out, vec![(6, 6)]);
}

#[test]
fn a_path_window_after_decomposed_folders_starts_at_the_basename() {
    let decomposed = "/Cafe\u{301}/Cre\u{300}me notes.txt";
    let composed_path = "/Café/Crème notes.txt";
    let a = Arena::from_paths([decomposed, composed_path]);
    let q = Query::new("creme");
    let hits = run(&a, "creme", None);
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].tier(), hits[1].tier());
    let mut scratch = HighlightScratch::default();
    let mut out = Vec::new();
    highlight::ranges(&a, 0, &q, decomposed, &mut scratch, &mut out);
    assert_eq!(out, vec![(7, 6)]);
    highlight::ranges(&a, 1, &q, composed_path, &mut scratch, &mut out);
    assert_eq!(out, vec![(6, 5)]);
}
