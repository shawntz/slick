//! The ranking contract in docs/ARCHITECTURE.md, one test per rule.

use crate::fixtures::{T0, app, command, context, engine, key, pick, titles};
use slick_engine::rank::{TIER_ALIAS_EXACT, TIER_ALIAS_PREFIX, TIER_LEARNED};
use slick_engine::{Item, Session, Source, hit_flags, kind};

/// Rule 1: a user alias that matches exactly or by prefix ranks first, above an exact title and
/// above the learned band.
#[test]
fn rule_1_user_aliases_rank_first() {
    let items = vec![app("Term"), app("Terminal"), app("TextEdit")];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    pick(&e, &items[1], "term", 3, &mut t); // Terminal is now in the learned band for "term"
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    e.set_alias(items[2].key, "term").expect("alias");
    let hits = e.query(&mut s, "term", 10).expect("query");
    assert_eq!(hits[0].key, items[2].key);
    assert_eq!(hits[0].tier, TIER_ALIAS_EXACT);
    assert_eq!(hits[1].tier, TIER_LEARNED);
    let hits = e.query(&mut s, "t", 10).expect("query");
    assert_eq!((hits[0].key, hits[0].tier), (items[2].key, TIER_ALIAS_PREFIX));
    assert!(hits[0].flags & hit_flags::ALIAS != 0);
    e.set_alias(items[2].key, "").expect("remove alias");
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
}

/// Rule 2: the strongest affinity entry for exactly this query, at decayed weight 1.5 or more,
/// ranks above an exact title. Typing "term" twice and picking Terminal both times beats an app
/// named Term; once does not.
#[test]
fn rule_2_the_learned_band_beats_an_exact_title() {
    let items = vec![app("Term"), app("Terminal")];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term");
    pick(&e, &items[1], "term", 1, &mut t);
    assert_eq!(
        titles(&e, &mut s, "term", &items)[0],
        "Term",
        "one pick is below the band"
    );
    pick(&e, &items[1], "term", 1, &mut t);
    let hits = e.query(&mut s, "term", 10).expect("query");
    assert_eq!(hits[0].key, items[1].key);
    assert_eq!(hits[0].tier, TIER_LEARNED);
    assert!(hits[0].flags & hit_flags::LEARNED != 0);
}

/// Rule 3: outside the bands a weaker tier never outranks a stronger one; frecency, context and
/// kind priors only reorder within a tier; affinity below the band lifts by at most one tier.
#[test]
fn rule_3_tiers_hold_and_affinity_lifts_one_tier_at_most() {
    // "gam": X is a word-prefix match (tier 4), Y an exact keyword (tier 5 for keywords),
    // Z an exact title (tier 6).
    let x = Item {
        prior: 0.4,
        ..app("Alpha Gamma")
    };
    let y = Item {
        keywords: vec!["gam".into()],
        ..command("Zeta Tool")
    };
    let z = command("Gam");
    let items = vec![x.clone(), y.clone(), z.clone()];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    // Give X every within-tier signal: most frecent, most likely in context, full static prior.
    // Suggestion picks teach no typed affinity.
    for _ in 0..30 {
        t += 60.0;
        e.record(x.key, "", Source::Suggestion, 0, t).expect("record");
    }
    e.set_context(context(t, 0)).expect("context");
    assert_eq!(
        titles(&e, &mut s, "gam", &items),
        vec!["Gam", "Zeta Tool", "Alpha Gamma"]
    );
    // One typed pick: affinity below the band lifts X over the next tier, not over two.
    pick(&e, &x, "gam", 1, &mut t);
    let hits = e.query(&mut s, "gam", 10).expect("query");
    let order: Vec<u64> = hits.iter().map(|h| h.key).collect();
    assert_eq!(order, vec![z.key, x.key, y.key]);
    assert!(hits[1].flags & hit_flags::AFFINITY != 0 && hits[1].tier == 4);
    // No signal reorders tiers across a broad query.
    for q in ["a", "g", "ga", "z", "t", "o"] {
        let hits = e.query(&mut s, q, 10).expect("query");
        for w in hits.windows(2) {
            if (w[0].flags | w[1].flags) & hit_flags::AFFINITY == 0 {
                assert!(w[0].tier >= w[1].tier, "{q}: {hits:?}");
            }
        }
    }
}

/// Rule 4: a habit flips in two selections, and one stray pick never flips it.
#[test]
fn rule_4_a_habit_flips_in_two_selections() {
    let items = vec![app("Slack"), app("Safari"), app("Stocks")];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    pick(&e, &items[0], "s", 20, &mut t);
    assert_eq!(titles(&e, &mut s, "s", &items)[0], "Slack");
    pick(&e, &items[1], "s", 1, &mut t);
    assert_eq!(titles(&e, &mut s, "s", &items)[0], "Slack", "one stray pick");
    pick(&e, &items[1], "s", 1, &mut t);
    assert_eq!(titles(&e, &mut s, "s", &items)[0], "Safari", "second pick");
    // A short habit flips just as fast.
    pick(&e, &items[2], "s", 2, &mut t);
    assert_eq!(titles(&e, &mut s, "s", &items)[0], "Stocks");
}

/// Rule 5: the same query against the same state returns the same order; ties break by shorter
/// title, then by key.
#[test]
fn rule_5_order_is_deterministic_with_title_then_key_tie_breaks() {
    let tied: Vec<Item> = ["Long Item Title", "Short", "Other Item Name", "Tiny"]
        .iter()
        .map(|t| Item {
            key: key(t),
            title: t.to_string(),
            keywords: vec!["zzz".into()],
            kind: kind::OTHER,
            ..Item::default()
        })
        .collect();
    let e = engine(tied.clone());
    let mut s = Session::new();
    let order = titles(&e, &mut s, "zzz", &tied);
    // Equal ranks: shorter titles first; the two 15-char titles by key.
    assert_eq!(&order[..2], &["Tiny", "Short"]);
    let (a, b) = (key("Long Item Title"), key("Other Item Name"));
    let expect = if a < b {
        ["Long Item Title", "Other Item Name"]
    } else {
        ["Other Item Name", "Long Item Title"]
    };
    assert_eq!(&order[2..], &expect);
    for q in ["zzz", "t", "item", "zz"] {
        let first: Vec<_> = e.query(&mut s, q, 20).expect("query").to_vec();
        let mut fresh = Session::new();
        let second: Vec<_> = e.query(&mut fresh, q, 20).expect("query").to_vec();
        assert_eq!(first, second, "{q}");
    }
}
