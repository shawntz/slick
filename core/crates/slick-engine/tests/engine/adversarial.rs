//! Adversarial property tests for the ranking contract: random catalogs whose titles, aliases and
//! keywords collide, random histories with clocks that jump both ways, undo, forget, removal and
//! re-adding, and queries of every length including empty and one character. After every step
//! each rule is checked against a model of what the test did.

use crate::fixtures::{T0, context, key};
use crate::rng::Rng;
use slick_engine::rank::{TIER_ALIAS_EXACT, TIER_ALIAS_PREFIX, TIER_LEARNED};
use slick_engine::{Engine, EngineParams, Hit, Item, Session, Source, hit_flags, kind};
use slick_match::{Arena, Opts, Query, Scratch, search};
use std::collections::HashMap;

/// Few, overlapping words, so titles, aliases and keywords collide and tie.
const WORDS: &[&str] = &[
    "term", "terminal", "Term", "safari", "saf", "s", "notes", "note", "mail", "maps", "music", "code", "x", "tool",
    "dark", "mode", "Search", "set", "settings", "a",
];

/// Lowercase, single spaces, trimmed: the engine's folding for the ASCII text these tests use.
fn fold(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn phrase(rng: &mut Rng, max_words: usize) -> String {
    let n = 1 + rng.below(max_words);
    (0..n).map(|_| *rng.pick(WORDS)).collect::<Vec<_>>().join(" ")
}

fn random_item(rng: &mut Rng, id: usize) -> Item {
    let aliases = (0..rng.below(2)).map(|_| phrase(rng, 1)).collect();
    let keywords = (0..rng.below(3)).map(|_| phrase(rng, 2)).collect();
    Item {
        key: key(&format!("prop:{id}")),
        title: phrase(rng, 3),
        aliases,
        keywords,
        kind: rng.below(6) as u8,
        prior: rng.below(5) as f32 / 4.0,
        flags: 0,
    }
}

/// A query a person might type against this catalog: a prefix of some title or alias, a word,
/// one character, or something with stray whitespace and case.
fn random_query(rng: &mut Rng, items: &[Item]) -> String {
    match rng.below(6) {
        0 if !items.is_empty() => {
            let t = &rng.pick(items).title;
            let cut = 1 + rng.below(t.len());
            t[..cut].to_string()
        }
        1 => rng.pick(WORDS).to_string(),
        2 => ((b'a' + rng.below(26) as u8) as char).to_string(),
        3 => format!("  {} ", rng.pick(WORDS).to_uppercase()),
        4 => phrase(rng, 2),
        _ => String::new(),
    }
}

/// What the test did to the engine, so each rule can be checked from the outside.
struct Model {
    catalog: Vec<Item>,
    removed: Vec<Item>,
    aliases: HashMap<u64, String>,
    t: f64,
}

impl Model {
    fn item(&self, key: u64) -> Option<&Item> {
        self.catalog.iter().find(|i| i.key == key)
    }

    fn title_len(&self, key: u64) -> usize {
        self.item(key).map_or(usize::MAX, |i| i.title.chars().count())
    }
}

fn all_hits(e: &Engine, s: &mut Session, q: &str) -> Vec<Hit> {
    e.query(s, q, 1_000).expect("query").to_vec()
}

/// Rule 1: every item whose user alias starts with the query ranks above every other hit, and
/// exact aliases above prefixes. Nothing else carries the alias flag.
fn check_rule_1(m: &Model, q: &str, hits: &[Hit]) {
    let fq = fold(q);
    if fq.is_empty() {
        assert!(hits.is_empty(), "{q:?}: an empty query has no hits");
        return;
    }
    let mut want: Vec<u64> = m
        .aliases
        .iter()
        .filter(|(k, a)| a.starts_with(&fq) && m.item(**k).is_some())
        .map(|(k, _)| *k)
        .collect();
    want.sort_unstable();
    let mut got: Vec<u64> = hits
        .iter()
        .filter(|h| h.flags & hit_flags::ALIAS != 0)
        .map(|h| h.key)
        .collect();
    got.sort_unstable();
    assert_eq!(got, want, "{q:?}: alias hits");
    let first_other = hits
        .iter()
        .position(|h| h.flags & hit_flags::ALIAS == 0)
        .unwrap_or(hits.len());
    assert!(
        hits[first_other..].iter().all(|h| h.flags & hit_flags::ALIAS == 0),
        "{q:?}: an alias hit ranks below a non-alias hit: {hits:?}"
    );
    for h in &hits[..first_other] {
        let exact = m.aliases.get(&h.key).is_some_and(|a| *a == fq);
        let tier = if exact { TIER_ALIAS_EXACT } else { TIER_ALIAS_PREFIX };
        assert_eq!(h.tier, tier, "{q:?}: alias tier");
    }
    for w in hits[..first_other].windows(2) {
        assert!(w[0].tier >= w[1].tier, "{q:?}: an alias prefix above an exact alias");
    }
}

/// Rules 2 and 3: band hits sit above text hits; text hits never fall out of tier order except
/// that query affinity lifts by at most one tier; the reported text tier is the matcher's tier
/// with no learning at all.
fn check_rule_2_3(q: &str, hits: &[Hit], plain: &HashMap<u64, u8>) {
    let text: Vec<&Hit> = hits.iter().filter(|h| h.tier < TIER_LEARNED).collect();
    let first_text = hits.iter().position(|h| h.tier < TIER_LEARNED).unwrap_or(hits.len());
    assert!(
        hits[first_text..].iter().all(|h| h.tier < TIER_LEARNED),
        "{q:?}: a band hit below a text hit: {hits:?}"
    );
    for h in &hits[..first_text] {
        assert!(
            h.flags & (hit_flags::ALIAS | hit_flags::LEARNED) != 0,
            "{q:?}: band without a flag"
        );
    }
    for (i, a) in text.iter().enumerate() {
        assert_eq!(
            plain.get(&a.key),
            Some(&a.tier),
            "{q:?}: text tier differs from the plain matcher"
        );
        for b in &text[i + 1..] {
            let lifted = a.flags & hit_flags::AFFINITY != 0;
            let limit = if lifted { a.tier + 1 } else { a.tier };
            assert!(
                b.tier <= limit,
                "{q:?}: tier {} above tier {} (lifted {lifted})",
                a.tier,
                b.tier
            );
        }
    }
}

/// Rule 5: ties break by shorter title, then by smaller key, and a narrowed session agrees with a
/// fresh one.
fn check_rule_5(m: &Model, e: &Engine, q: &str, hits: &[Hit], typed: &mut Session) {
    for w in hits.windows(2) {
        assert!(w[0].rank >= w[1].rank, "{q:?}: not sorted by rank");
        if w[0].rank == w[1].rank {
            let (a, b) = ((m.title_len(w[0].key), w[0].key), (m.title_len(w[1].key), w[1].key));
            assert!(a < b, "{q:?}: tie not broken by title length then key: {a:?} {b:?}");
        }
    }
    // Type the query one char at a time, with a stray char and a backspace in the middle.
    let chars: Vec<char> = q.chars().collect();
    for n in 1..=chars.len() {
        let prefix: String = chars[..n].iter().collect();
        e.query(typed, &prefix, 1_000).expect("query");
        if n == chars.len() / 2 {
            e.query(typed, &format!("{prefix}z"), 1_000).expect("query");
        }
    }
    let narrowed = all_hits(e, typed, q);
    assert_eq!(narrowed, hits, "{q:?}: a narrowed session differs from a fresh one");
    assert_eq!(
        all_hits(e, &mut Session::new(), q),
        hits,
        "{q:?}: the same query changed"
    );
}

/// Every item's text tier from the matcher alone, as root search runs it: a whole later word ranks
/// with literal prefixes, and there is no lift and no learning.
fn plain_tiers(m: &Model, q: &str) -> HashMap<u64, u8> {
    let mut arena = Arena::new(false);
    for i in &m.catalog {
        arena.push_item(
            &i.title,
            i.aliases.iter().map(String::as_str),
            i.keywords.iter().map(String::as_str),
        );
    }
    let opts = Opts {
        k: m.catalog.len().max(1),
        ..Opts::default()
    };
    let mut hits = Vec::new();
    let query = Query::with_whole_words(q);
    search(&arena, &query, &opts, None, None, &mut Scratch::default(), &mut hits);
    hits.iter().map(|h| (m.catalog[h.idx as usize].key, h.tier())).collect()
}

fn check_all(m: &Model, e: &Engine, rng: &mut Rng) {
    for _ in 0..6 {
        let q = random_query(rng, &m.catalog);
        let hits = all_hits(e, &mut Session::new(), &q);
        check_rule_1(m, &q, &hits);
        check_rule_2_3(&q, &hits, &plain_tiers(m, &q));
        check_rule_5(m, e, &q, &hits, &mut Session::new());
    }
}

/// One random step: a pick, an undo, a forget, a catalog change, an alias change or a context
/// change. Times move forward by up to three days, and now and then jump back or ahead.
fn step(m: &mut Model, e: &Engine, rng: &mut Rng, next_id: &mut usize) {
    m.t += match rng.below(20) {
        0 => -40.0 * 86_400.0,
        1 => 400.0 * 86_400.0,
        _ => (1 + rng.below(3 * 86_400)) as f64,
    };
    match rng.below(10) {
        0..=4 if !m.catalog.is_empty() => {
            let item = rng.pick(&m.catalog).clone();
            let q = random_query(rng, &m.catalog);
            let source = [Source::Typed, Source::Typed, Source::Suggestion, Source::Fallback][rng.below(4)];
            e.record(item.key, &q, source, 0, m.t).expect("record");
            if rng.below(8) == 0 {
                e.undo(item.key, m.t + 1.0).expect("undo");
            }
        }
        5 if !m.catalog.is_empty() => {
            let k = rng.pick(&m.catalog).key;
            e.forget(k).expect("forget");
        }
        6 if !m.catalog.is_empty() => {
            let i = rng.below(m.catalog.len());
            let item = m.catalog.swap_remove(i);
            e.remove(item.key).expect("remove");
            m.removed.push(item);
        }
        7 if !m.removed.is_empty() => {
            let i = rng.below(m.removed.len());
            let item = m.removed.swap_remove(i);
            e.upsert(1, item.clone()).expect("upsert");
            m.catalog.push(item);
        }
        8 => {
            *next_id += 1;
            let item = random_item(rng, *next_id);
            e.upsert(2, item.clone()).expect("upsert");
            m.catalog.push(item);
        }
        _ if !m.catalog.is_empty() => {
            let k = rng.pick(&m.catalog).key;
            let alias = if rng.below(3) == 0 {
                String::new()
            } else {
                phrase(rng, 1)
            };
            e.set_alias(k, &alias).expect("alias");
            if alias.is_empty() {
                m.aliases.remove(&k);
            } else {
                m.aliases.insert(k, fold(&alias));
            }
        }
        _ => {}
    }
    if rng.below(4) == 0 {
        e.set_context(context(m.t, 0)).expect("context");
    }
}

fn random_engine(rng: &mut Rng, next_id: &mut usize) -> (Engine, Model) {
    let e = Engine::in_memory(EngineParams::default());
    let n = 5 + rng.below(30);
    let catalog: Vec<Item> = (0..n)
        .map(|_| {
            *next_id += 1;
            random_item(rng, *next_id)
        })
        .collect();
    e.replace_source(1, catalog.clone()).expect("catalog");
    e.set_context(context(T0, 0)).expect("context");
    let m = Model {
        catalog,
        removed: Vec::new(),
        aliases: HashMap::new(),
        t: T0,
    };
    (e, m)
}

#[test]
fn every_rule_holds_through_random_histories() {
    for seed in 0..60 {
        let mut rng = Rng::new(seed);
        let mut next_id = 0;
        let (e, mut m) = random_engine(&mut rng, &mut next_id);
        for _ in 0..40 {
            step(&mut m, &e, &mut rng, &mut next_id);
            check_all(&m, &e, &mut rng);
        }
    }
}

/// True when `x` ranks above every hit for `q` that is not a user-alias hit of another item
/// (rule 1 puts those first, whatever was learned).
fn leads(e: &Engine, q: &str, x: u64) -> bool {
    let hits = all_hits(e, &mut Session::new(), q);
    let first = hits.iter().position(|h| h.key == x || h.flags & hit_flags::ALIAS == 0);
    first.is_some_and(|i| hits[i].key == x)
}

/// Rules 2 and 4 from any history: two consecutive picks of an item for a query put it first
/// (below user aliases), and that two-pick habit survives one stray pick, even when the stray item
/// was a long habit just before. Each check runs with the context clock at the time of the picks.
#[test]
fn habits_flip_in_two_picks_and_survive_one_stray_pick_after_any_history() {
    for seed in 100..160 {
        let mut rng = Rng::new(seed);
        let mut next_id = 0;
        let (e, mut m) = random_engine(&mut rng, &mut next_id);
        for _ in 0..rng.below(60) {
            step(&mut m, &e, &mut rng, &mut next_id);
        }
        if m.catalog.len() < 2 {
            continue;
        }
        for _ in 0..8 {
            let q = loop {
                let q = random_query(&mut rng, &m.catalog);
                if !fold(&q).is_empty() {
                    break q;
                }
            };
            let x = rng.pick(&m.catalog).key;
            let y = loop {
                let y = rng.pick(&m.catalog).key;
                if y != x {
                    break y;
                }
            };
            // Sometimes a long habit of the stray item first.
            for _ in 0..[0, 0, 3, 30][rng.below(4)] {
                m.t += 60.0;
                e.record(y, &q, Source::Typed, 0, m.t).expect("record");
            }
            for _ in 0..2 {
                m.t += 60.0;
                e.record(x, &q, Source::Typed, 0, m.t).expect("record");
            }
            e.set_context(context(m.t, 0)).expect("context");
            assert!(leads(&e, &q, x), "seed {seed} {q:?}: two picks");
            m.t += 60.0;
            e.record(y, &q, Source::Typed, 0, m.t).expect("record");
            e.set_context(context(m.t, 0)).expect("context");
            assert!(leads(&e, &q, x), "seed {seed} {q:?}: one stray pick");
            m.t += 60.0;
            e.record(y, &q, Source::Typed, 0, m.t).expect("record");
            e.set_context(context(m.t, 0)).expect("context");
            assert!(leads(&e, &q, y), "seed {seed} {q:?}: the second pick flips");
        }
    }
}

fn two(a: &str, b: &str) -> (Engine, Item, Item) {
    let x = Item {
        key: key(&format!("app:{a}")),
        title: a.into(),
        kind: kind::APP,
        ..Item::default()
    };
    let y = Item {
        key: key(&format!("app:{b}")),
        title: b.into(),
        kind: kind::APP,
        ..Item::default()
    };
    let e = Engine::in_memory(EngineParams::default());
    e.replace_source(1, vec![x.clone(), y.clone()]).expect("catalog");
    e.set_context(context(T0, 0)).expect("context");
    (e, x, y)
}

/// The architecture's own example of rule 2, continued with rule 4: after "term" picked Terminal
/// twice, one pick of the exact title Term must not take first place back.
#[test]
fn the_two_pick_habit_of_the_example_survives_one_stray_pick() {
    let (e, term, terminal) = two("Term", "Terminal");
    let mut t = T0;
    for _ in 0..2 {
        t += 60.0;
        e.record(terminal.key, "term", Source::Typed, 0, t).expect("record");
    }
    assert!(leads(&e, "term", terminal.key), "two picks");
    t += 60.0;
    e.record(term.key, "term", Source::Typed, 0, t).expect("record");
    assert!(leads(&e, "term", terminal.key), "one stray pick");
    t += 60.0;
    e.record(term.key, "term", Source::Typed, 0, t).expect("record");
    assert!(leads(&e, "term", term.key), "the second pick flips");
}

/// The verifier's case for rule 4: after a long habit of Term, two picks of Terminal take "term",
/// and one more pick of Term does not take it back. A second one does.
#[test]
fn a_new_two_pick_habit_survives_one_pick_of_a_long_old_habit() {
    let (e, term, terminal) = two("Term", "Terminal");
    let mut t = T0;
    let mut pick = |key: u64| {
        t += 60.0;
        e.record(key, "term", Source::Typed, 0, t).expect("record");
        e.set_context(context(t, 0)).expect("context");
    };
    for _ in 0..30 {
        pick(term.key);
    }
    for _ in 0..2 {
        pick(terminal.key);
    }
    assert!(leads(&e, "term", terminal.key), "two picks of the new habit");
    pick(term.key);
    assert!(leads(&e, "term", terminal.key), "one pick of the old habit");
    pick(term.key);
    assert!(leads(&e, "term", term.key), "two picks of the old habit");
}

/// A clock set back (or a context time of zero before the app sets one) must not let one pick
/// into the band, and a pick stamped in the future must not lock a habit in.
#[test]
fn clocks_that_jump_never_break_the_band() {
    let (e, term, terminal) = two("Term", "Terminal");
    e.record(terminal.key, "term", Source::Typed, 0, T0).expect("record");
    for now in [T0 - 300.0 * 86_400.0, 0.0, f64::NAN] {
        e.set_context(context(now, 0)).expect("context");
        assert!(leads(&e, "term", term.key), "one pick, context time {now}");
    }
    let (e, term, terminal) = two("Term", "Terminal");
    let future = T0 + 365.0 * 86_400.0;
    for k in 0..10 {
        e.record(terminal.key, "term", Source::Typed, 0, future + k as f64)
            .expect("record");
    }
    let mut t = T0;
    for _ in 0..2 {
        t += 60.0;
        e.record(term.key, "term", Source::Typed, 0, t).expect("record");
    }
    e.set_context(context(t, 0)).expect("context");
    assert!(leads(&e, "term", term.key), "two picks flip a future-dated habit");
}

/// Removing an item keeps its learning, and re-adding it restores its place; forgetting it drops
/// the band for good.
#[test]
fn removed_readded_and_forgotten_items() {
    let (e, term, terminal) = two("Term", "Terminal");
    let mut t = T0;
    for _ in 0..3 {
        t += 60.0;
        e.record(terminal.key, "term", Source::Typed, 0, t).expect("record");
    }
    e.remove(terminal.key).expect("remove");
    let hits = all_hits(&e, &mut Session::new(), "term");
    assert!(
        hits.iter().all(|h| h.key != terminal.key),
        "a removed item is never a hit"
    );
    assert_eq!(hits[0].key, term.key);
    e.upsert(1, terminal.clone()).expect("re-add");
    let hits = all_hits(&e, &mut Session::new(), "term");
    assert_eq!((hits[0].key, hits[0].tier), (terminal.key, TIER_LEARNED));
    e.forget(terminal.key).expect("forget");
    let hits = all_hits(&e, &mut Session::new(), "term");
    assert_eq!(hits[0].key, term.key);
    assert!(
        hits.iter()
            .all(|h| h.flags & (hit_flags::LEARNED | hit_flags::AFFINITY) == 0)
    );
    // An alias equal to another item's exact title still ranks first, for the empty-alias item too.
    e.set_alias(term.key, "terminal").expect("alias");
    let hits = all_hits(&e, &mut Session::new(), "Terminal");
    assert_eq!((hits[0].key, hits[0].tier), (term.key, TIER_ALIAS_EXACT));
}
