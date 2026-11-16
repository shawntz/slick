//! Property tests on random synthetic corpora:
//!
//! - narrowing returns exactly what a full scan returns, for random typing with backspaces;
//! - the bounded top k equals a full sort of every item's best rank, with exact keywords in the
//!   exact tier or one tier down;
//! - nothing panics on arbitrary UTF-8, including empty strings, emoji, CJK and combining marks,
//!   and highlight ranges always fall inside the original text.

use crate::corpus;
use crate::rng::Rng;
use slick_match::highlight::{self, HighlightScratch};
use slick_match::rank::{self, Field};
use slick_match::score::WORD_PREFIX;
use slick_match::search::score_entry;
use slick_match::{Arena, Hit, MAX_LIFT, Opts, Query, Scratch, Session, search, search_seeded};

/// Characters that stress folding, word starts and the byte and char paths.
const POOL: &[char] = &[
    'a',
    'b',
    'c',
    'd',
    'e',
    'g',
    'h',
    'i',
    'm',
    'o',
    'r',
    's',
    't',
    'A',
    'G',
    'H',
    'S',
    'T',
    'Y',
    '0',
    '7',
    ' ',
    ' ',
    '-',
    '_',
    '.',
    '/',
    ':',
    '&',
    '\t',
    '\n',
    'é',
    'É',
    'ß',
    'ø',
    'İ',
    'ﬁ',
    '\u{301}',
    '\u{200B}',
    '\u{200D}',
    '\u{FEFF}',
    '\u{FFFD}',
    '微',
    '信',
    'カ',
    'レ',
    '한',
    'ب',
    'Ж',
    'λ',
    '🎉',
    '😀',
    '👩',
    '🏽',
    '🇫',
    '🇷',
    '\u{10FFFF}',
];

fn random_text(rng: &mut Rng, max_len: usize) -> String {
    (0..rng.below(max_len + 1))
        .map(|_| POOL[rng.below(POOL.len())])
        .collect()
}

/// An arena mixing generated titles, random Unicode and multi-string items, with its sources.
struct Corpus {
    arena: Arena,
    titles: Vec<String>,
}

fn random_corpus(seed: u64, n: usize) -> Corpus {
    let mut rng = Rng::new(seed);
    let generated = corpus::titles(n, seed);
    let mut arena = Arena::new(false);
    let mut titles = Vec::with_capacity(n);
    for g in generated {
        let title = match rng.below(6) {
            0 => random_text(&mut rng, 24),
            _ => g,
        };
        let aliases: Vec<String> = (0..rng.below(3)).map(|_| random_text(&mut rng, 12)).collect();
        let keywords: Vec<String> = (0..rng.below(3))
            .map(|_| match rng.below(2) {
                0 => corpus::titles(1, rng.next())[0].clone(),
                _ => random_text(&mut rng, 16),
            })
            .collect();
        arena.push_item(
            &title,
            aliases.iter().map(String::as_str),
            keywords.iter().map(String::as_str),
        );
        titles.push(title);
    }
    Corpus { arena, titles }
}

fn random_lift(rng: &mut Rng, n: usize) -> Vec<i32> {
    (0..n)
        .map(|_| match rng.below(4) {
            0 => 0,
            1 => MAX_LIFT,
            _ => rng.below(MAX_LIFT as usize + 1) as i32,
        })
        .collect()
}

/// The typing target for one sequence: a word run from a title, an acronym, a later word of a
/// title, or random text.
fn target(rng: &mut Rng, c: &Corpus) -> String {
    let t = &c.titles[rng.below(c.titles.len())];
    match rng.below(5) {
        0 => t.split_whitespace().filter_map(|w| w.chars().next()).collect(),
        1 => random_text(rng, 8),
        2 => t.split_whitespace().last().unwrap_or("").to_lowercase(),
        _ => t.to_lowercase(),
    }
}

/// A query as file search folds it (`whole` false) or as root search does (`whole` true), with a
/// keyword equal to the query in the exact tier, as feature indexes rank it, when `exact_keywords`.
fn query(typed: &str, whole: bool, exact_keywords: bool) -> Query {
    let mut q = Query::default();
    q.whole_words = whole;
    q.exact_keywords = exact_keywords;
    q.set(typed);
    q
}

fn full_scan(a: &Arena, q: &Query, opts: &Opts, lift: Option<&[i32]>) -> Vec<Hit> {
    let mut scratch = Scratch::default();
    let mut out = Vec::new();
    search(a, q, opts, None, lift, &mut scratch, &mut out);
    out
}

#[test]
fn narrowing_equals_a_full_scan() {
    for seed in 0..6u64 {
        let c = random_corpus(seed, 1_500);
        let mut rng = Rng::new(seed ^ 0xABCD);
        let lift = random_lift(&mut rng, c.arena.len());
        let opts = Opts {
            k: 1 + rng.below(60),
            ..Opts::default()
        };
        let mut session = Session::default();
        let mut narrowed = Vec::new();
        let mut q = Query::default();
        for round in 0..40 {
            let goal = target(&mut rng, &c);
            let mut typed = String::new();
            // The session narrows the same way whether the promotions are on or not.
            q.whole_words = round % 2 == 1;
            q.exact_keywords = round % 4 >= 2;
            for ch in goal.chars().take(14) {
                typed.push(ch);
                if rng.below(6) == 0 {
                    typed.pop();
                }
                q.set(&typed);
                let use_lift = (rng.below(2) == 0).then_some(lift.as_slice());
                session.search(&c.arena, &q, &opts, use_lift, &mut narrowed);
                assert_eq!(
                    narrowed,
                    full_scan(&c.arena, &q, &opts, use_lift),
                    "seed {seed} query {typed:?} whole words {} exact keywords {}",
                    q.whole_words,
                    q.exact_keywords
                );
            }
            if rng.below(3) == 0 {
                session.reset();
            }
        }
    }
}

/// Every item's best rank, computed entry by entry with the scalar reference and no bound.
fn reference(a: &Arena, q: &Query, opts: &Opts, lift: &[i32]) -> Vec<Hit> {
    let mut chars = Vec::new();
    let mut best: Vec<Option<(i32, Field)>> = vec![None; a.len()];
    let mut best_strict = i32::MIN;
    for (i, slot) in best.iter_mut().enumerate() {
        for e in a.entry_range(i) {
            let field = a.field(e);
            if let Some(r) = score_entry(a, e, q, opts, false, &mut chars)
                .and_then(|t| rank::rank(t, field, lift[i], q.exact_keywords))
                && slot.is_none_or(|(b, _)| r > b)
            {
                *slot = Some((r, field));
            }
        }
        if let Some((r, _)) = *slot {
            best_strict = best_strict.max(r);
        }
    }
    let typo = q.len_chars() >= 4 && (best_strict == i32::MIN || rank::tier_of(best_strict) < WORD_PREFIX);
    if typo {
        for (i, slot) in best.iter_mut().enumerate() {
            for e in a.entry_range(i).filter(|&e| a.field(e) != Field::Keyword) {
                let field = a.field(e);
                if let Some(r) = score_entry(a, e, q, opts, true, &mut chars)
                    .and_then(|t| rank::rank(t, field, lift[i], q.exact_keywords))
                    && slot.is_none_or(|(b, _)| r > b)
                {
                    *slot = Some((r, field));
                }
            }
        }
    }
    let mut all: Vec<Hit> = best
        .iter()
        .enumerate()
        .filter_map(|(i, b)| {
            b.map(|(rank, field)| Hit {
                idx: i as u32,
                rank,
                field,
            })
        })
        .collect();
    all.sort_by(|x, y| y.rank.cmp(&x.rank).then(x.idx.cmp(&y.idx)));
    all.truncate(opts.k);
    all
}

#[test]
fn top_k_equals_a_full_sort() {
    for seed in 10..16u64 {
        let c = random_corpus(seed, 2_000);
        let mut rng = Rng::new(seed);
        let lift = random_lift(&mut rng, c.arena.len());
        for round in 0..60 {
            let goal = target(&mut rng, &c);
            let len = 1 + rng.below(goal.chars().count().clamp(1, 12));
            let typed: String = goal.chars().take(len).collect();
            let q = query(&typed, round % 2 == 1, round % 4 >= 2);
            let opts = Opts {
                k: 1 + rng.below(80),
                ..Opts::default()
            };
            let got = full_scan(&c.arena, &q, &opts, Some(&lift));
            assert_eq!(
                got,
                reference(&c.arena, &q, &opts, &lift),
                "seed {seed} query {typed:?} whole words {} exact keywords {}",
                q.whole_words,
                q.exact_keywords
            );
        }
    }
}

#[test]
fn arbitrary_unicode_never_panics() {
    let mut rng = Rng::new(7);
    let mut hl = HighlightScratch::default();
    let mut ranges = Vec::new();
    for round in 0..30 {
        let n = rng.below(200);
        let texts: Vec<String> = (0..n).map(|_| random_text(&mut rng, 40)).collect();
        let paths: Vec<String> = texts.iter().map(|t| format!("/synthetic/{t}/{t}")).collect();
        let mut items = Arena::new(false);
        for (i, t) in texts.iter().enumerate() {
            items.push_item(t, [texts[(i + 1) % n.max(1)].as_str()], [""]);
        }
        for arena in [
            Arena::from_titles(texts.iter().map(String::as_str)),
            Arena::from_paths(paths.iter().map(String::as_str)),
            items,
        ] {
            let mut session = Session::default();
            let mut out = Vec::new();
            for i in 0..20 {
                let q = query(&random_text(&mut rng, 10), i % 2 == 1, i % 4 >= 2);
                let opts = Opts {
                    path_fallback: round % 2 == 0,
                    ..Opts::default()
                };
                session.search(&arena, &q, &opts, None, &mut out);
                for h in &out {
                    let e = arena.entry_range(h.idx as usize).start;
                    let orig = if arena.paths {
                        &paths[h.idx as usize]
                    } else {
                        &texts[h.idx as usize]
                    };
                    highlight::ranges(&arena, e, &q, orig, &mut hl, &mut ranges);
                    let units = orig.encode_utf16().count() as u32;
                    let mut end = 0;
                    for &(start, len) in &ranges {
                        assert!(start >= end && len > 0 && start + len <= units, "{orig:?} {ranges:?}");
                        end = start + len;
                    }
                }
            }
        }
    }
    // Generated file paths with the full-path fallback.
    let paths = corpus::paths(3_000, 3);
    let arena = Arena::from_paths(paths.iter().map(String::as_str));
    let opts = Opts {
        path_fallback: true,
        ..Opts::default()
    };
    for typed in ["readme", "src main", "scr 2024", "img", "syn", "🎉"] {
        let q = Query::new(typed);
        assert_eq!(
            full_scan(&arena, &q, &opts, None),
            reference(&arena, &q, &opts, &vec![0; arena.len()])
        );
    }
    // Empty everything.
    let empty = Arena::new(false);
    let mut out = Vec::new();
    search(
        &empty,
        &Query::new(""),
        &Opts::default(),
        None,
        None,
        &mut Scratch::default(),
        &mut out,
    );
    search(
        &empty,
        &Query::new("abc"),
        &Opts::default(),
        None,
        None,
        &mut Scratch::default(),
        &mut out,
    );
    assert!(out.is_empty());
}

/// Lifts shaped like a learned catalog: most items low, a few hundred high.
fn learned_lift(rng: &mut Rng, n: usize) -> Vec<i32> {
    (0..n)
        .map(|_| match rng.below(10) {
            0 => 1_000 + rng.below(MAX_LIFT as usize - 999) as i32,
            1 => 600,
            _ => rng.below(300) as i32,
        })
        .collect()
}

/// The bound that skips entries before the bit path, the seeds that set its threshold, and the
/// superset narrowing set it leaves never change a result: short queries (where the bound does the
/// most) on launcher-shaped titles with learned lifts give the same hits with and without the
/// bound and the seeds, as the scalar reference, and typed one char at a time.
#[test]
fn seeds_and_the_bound_never_change_a_result() {
    for seed in 20..26u64 {
        let c = random_corpus(seed, 3_000);
        let n = c.arena.len();
        let mut rng = Rng::new(seed);
        let lift = learned_lift(&mut rng, n);
        let mut seeds: Vec<u32> = (0..n as u32).filter(|&i| lift[i as usize] >= 1_000).collect();
        seeds.extend([0, 0, n as u32, u32::MAX]);
        for round in 0..80 {
            let goal = target(&mut rng, &c);
            let len = 1 + rng.below(goal.chars().count().clamp(1, 4));
            let typed: String = goal.chars().take(len).collect();
            let whole = round % 2 == 1;
            let q = query(&typed, whole, round % 4 >= 2);
            let opts = Opts {
                k: [1, 10, 50, 80][rng.below(4)],
                ..Opts::default()
            };
            let want = reference(&c.arena, &q, &opts, &lift);
            let unbounded = Opts { bound: false, ..opts };
            assert_eq!(
                full_scan(&c.arena, &q, &unbounded, Some(&lift)),
                want,
                "seed {seed} {typed:?} whole {whole} no bound"
            );
            assert_eq!(
                full_scan(&c.arena, &q, &opts, Some(&lift)),
                want,
                "seed {seed} {typed:?} whole {whole} bound"
            );
            let mut scratch = Scratch::default();
            let mut out = Vec::new();
            search_seeded(&c.arena, &q, &opts, None, Some(&lift), &seeds, &mut scratch, &mut out);
            assert_eq!(out, want, "seed {seed} {typed:?} whole {whole} seeded");
            // Every item that passes the gate is in the narrowing set.
            let mut chars = Vec::new();
            for i in 0..n {
                let gated = c.arena.entry_range(i).any(|e| {
                    score_entry(&c.arena, e, &q, &opts, false, &mut chars).is_some()
                        || slick_match::score::is_strict_match(&q.needle(), c.arena.window(e))
                });
                if gated && q.ascii && !q.is_empty() {
                    assert!(
                        scratch.matched.contains(&(i as u32)),
                        "seed {seed} {typed:?}: item {i} left the narrowing set"
                    );
                }
            }
        }
        // Typing with seeds narrows exactly too.
        let mut session = Session::default();
        let mut narrowed = Vec::new();
        let opts = Opts::default();
        for round in 0..20 {
            let goal = target(&mut rng, &c);
            let mut typed = String::new();
            for ch in goal.chars().take(8) {
                typed.push(ch);
                let q = query(&typed, round % 2 == 1, round % 4 >= 2);
                session.search_seeded(&c.arena, &q, &opts, Some(&lift), &seeds, &mut narrowed);
                assert_eq!(
                    narrowed,
                    reference(&c.arena, &q, &opts, &lift),
                    "seed {seed} typed {typed:?} whole words {}",
                    q.whole_words
                );
            }
            session.reset();
        }
    }
}

/// Feature indexes rank a keyword equal to the query in the exact tier. Over items whose keywords
/// are words of the corpus's titles, so a typed word often equals a keyword and also starts or
/// ends titles, the bound, the seeds and narrowing return exactly what the scalar reference does.
#[test]
fn exact_keywords_never_change_a_result() {
    for seed in 30..34u64 {
        let mut rng = Rng::new(seed);
        let titles = corpus::titles(2_500, seed);
        let mut words: Vec<String> = titles
            .iter()
            .flat_map(|t| t.split_whitespace())
            .map(str::to_lowercase)
            .filter(|w| w.chars().count() >= 2)
            .collect();
        words.sort();
        words.dedup();
        let mut arena = Arena::new(false);
        for t in &titles {
            let keywords: Vec<&str> = (0..rng.below(4))
                .map(|_| words[rng.below(words.len())].as_str())
                .collect();
            arena.push_item(t, [], keywords);
        }
        let n = arena.len();
        let lift = learned_lift(&mut rng, n);
        let seeds: Vec<u32> = (0..n as u32).filter(|&i| lift[i as usize] >= 1_000).collect();
        let mut exact_keyword_tops = 0;
        for round in 0..120 {
            let word = &words[rng.below(words.len())];
            let len = match rng.below(3) {
                0 => 1 + rng.below(word.chars().count()),
                _ => word.chars().count(),
            };
            let typed: String = word.chars().take(len).collect();
            let q = query(&typed, round % 2 == 1, true);
            let opts = Opts {
                k: [1, 5, 20, 50][rng.below(4)],
                ..Opts::default()
            };
            let want = reference(&arena, &q, &opts, &lift);
            exact_keyword_tops += want.first().is_some_and(|h| h.field == Field::Keyword && h.tier() == 6) as usize;
            let unbounded = Opts { bound: false, ..opts };
            assert_eq!(
                full_scan(&arena, &q, &unbounded, Some(&lift)),
                want,
                "seed {seed} {typed:?} no bound"
            );
            assert_eq!(
                full_scan(&arena, &q, &opts, Some(&lift)),
                want,
                "seed {seed} {typed:?} bound"
            );
            let mut scratch = Scratch::default();
            let mut out = Vec::new();
            search_seeded(&arena, &q, &opts, None, Some(&lift), &seeds, &mut scratch, &mut out);
            assert_eq!(out, want, "seed {seed} {typed:?} seeded");
        }
        assert!(
            exact_keyword_tops > 10,
            "seed {seed}: {exact_keyword_tops} exact keywords on top"
        );
        let mut session = Session::default();
        let mut narrowed = Vec::new();
        let opts = Opts::default();
        for round in 0..30 {
            let word = &words[rng.below(words.len())];
            let mut typed = String::new();
            for ch in word.chars() {
                typed.push(ch);
                let q = query(&typed, round % 2 == 1, true);
                session.search_seeded(&arena, &q, &opts, Some(&lift), &seeds, &mut narrowed);
                assert_eq!(
                    narrowed,
                    reference(&arena, &q, &opts, &lift),
                    "seed {seed} typed {typed:?}"
                );
            }
            if rng.below(2) == 0 {
                session.reset();
            }
        }
    }
}
