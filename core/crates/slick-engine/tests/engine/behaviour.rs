//! Engine behaviour beyond the ranking rules: match strings, highlights, completion, context and
//! suggestions, undo, forget, pause, reset, flags, statistics and sessions.

use crate::fixtures::{T0, app, command, context, engine, key, pick, titles};
use slick_engine::{FIELD_USER_ALIAS, Item, Session, Source, flags, kind};

#[test]
fn every_match_string_finds_the_item_once() {
    let code = Item {
        aliases: vec!["VS Code".into()],
        keywords: vec!["editor".into(), "ide".into()],
        ..app("Visual Studio Code")
    };
    let items = vec![code.clone(), app("Editorial"), command("Code Snippets")];
    let e = engine(items.clone());
    let mut s = Session::new();
    for q in ["visual", "vs code", "editor", "ide", "vsc"] {
        let hits = e.query(&mut s, q, 10).expect("query");
        assert_eq!(hits.iter().filter(|h| h.key == code.key).count(), 1, "{q}");
    }
    // A keyword ranks one tier below the same match on a title.
    assert_eq!(
        titles(&e, &mut s, "editor", &items),
        vec!["Editorial", "Visual Studio Code"]
    );
    let hits = e.query(&mut s, "vs code", 10).expect("query");
    assert_eq!((hits[0].key, hits[0].field), (code.key, 1));
}

#[test]
fn highlight_ranges_are_utf16_and_computed_for_the_title() {
    let items = vec![app("Café Finder"), app("🎉 Confetti"), app("Visual Studio Code")];
    let e = engine(items.clone());
    let mut s = Session::new();
    e.query(&mut s, "cafe", 10).expect("query");
    assert_eq!(e.ranges(&mut s, items[0].key).expect("ranges"), &[(0, 4)]);
    e.query(&mut s, "conf", 10).expect("query");
    assert_eq!(e.ranges(&mut s, items[1].key).expect("ranges"), &[(3, 4)]);
    e.query(&mut s, "vsc", 10).expect("query");
    assert_eq!(
        e.ranges(&mut s, items[2].key).expect("ranges"),
        &[(0, 1), (7, 1), (14, 1)]
    );
    assert!(e.ranges(&mut s, key("missing")).expect("ranges").is_empty());
}

#[test]
fn inline_completion_needs_a_decisive_literal_prefix() {
    let items = vec![app("Safari"), app("Slack"), app("Spotify"), app("Terminal")];
    let e = engine(items.clone());
    let mut s = Session::new();
    e.query(&mut s, "saf", 10).expect("query");
    assert_eq!(e.completion(&mut s).expect("completion"), Some((items[0].key, "ari")));
    // "s" is ambiguous: Safari, Slack and Spotify are close.
    e.query(&mut s, "s", 10).expect("query");
    assert_eq!(e.completion(&mut s).expect("completion"), None);
    // The learned band makes it decisive.
    let mut t = T0;
    pick(&e, &items[1], "s", 2, &mut t);
    e.query(&mut s, "s", 10).expect("query");
    assert_eq!(e.completion(&mut s).expect("completion"), Some((items[1].key, "lack")));
    // Not a literal prefix: no completion, whatever the margin.
    e.query(&mut s, "trm", 10).expect("query");
    assert_eq!(e.completion(&mut s).expect("completion"), None);
    // A user alias completes as itself.
    e.set_alias(items[3].key, "tt").expect("alias");
    let hits = e.query(&mut s, "t", 10).expect("query");
    assert_eq!(hits[0].field, FIELD_USER_ALIAS);
    assert_eq!(e.completion(&mut s).expect("completion"), Some((items[3].key, "t")));
    // An exact title has nothing left to complete.
    e.query(&mut s, "safari", 10).expect("query");
    assert_eq!(e.completion(&mut s).expect("completion"), None);
}

#[test]
fn suggestions_follow_context_and_never_include_the_frontmost_app() {
    let items = vec![app("Mail"), app("Music"), app("Notes"), command("Lock Screen")];
    let e = engine(items.clone());
    let mut t = T0;
    for day in 0..10 {
        let morning = T0 + day as f64 * 86_400.0;
        let mut c = context(morning, 0);
        c.hour = 9;
        e.set_context(c).expect("context");
        e.record(items[0].key, "", Source::Suggestion, 0, morning)
            .expect("record");
        c.hour = 21;
        c.now = morning + 12.0 * 3_600.0;
        e.set_context(c).expect("context");
        e.record(items[1].key, "", Source::Suggestion, 0, c.now)
            .expect("record");
        t = c.now;
    }
    let mut out = Vec::new();
    let mut c = context(t + 86_400.0 - 12.0 * 3_600.0, 0);
    c.hour = 9;
    e.set_context(c).expect("context");
    e.suggestions(&mut out).expect("suggestions");
    assert_eq!(out[0].0, items[0].key, "Mail in the morning");
    c.frontmost = items[0].key;
    e.set_context(c).expect("context");
    e.suggestions(&mut out).expect("suggestions");
    assert!(
        out.iter().all(|&(k, _)| k != items[0].key),
        "the frontmost app is never suggested"
    );
    assert_eq!(out[0].0, items[1].key);
}

#[test]
fn undo_removes_an_execution_within_five_seconds() {
    let items = vec![app("Term"), app("Terminal")];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    pick(&e, &items[1], "term", 2, &mut t);
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    assert!(!e.undo(items[1].key, t + 6.0).expect("undo"), "too late");
    assert!(!e.undo(items[0].key, t + 1.0).expect("undo"), "not the last item");
    assert!(e.undo(items[1].key, t + 4.0).expect("undo"));
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term", "the second pick is gone");
    let stats = e.stats_json().expect("stats");
    assert!(stats.contains("\"events\":1,\"undone\":1"), "{stats}");
}

#[test]
fn forget_pause_and_reset() {
    let items = vec![app("Term"), app("Terminal")];
    let e = engine(items.clone());
    let mut s = Session::new();
    let mut t = T0;
    pick(&e, &items[1], "term", 2, &mut t);
    e.forget(items[1].key).expect("forget");
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term");
    assert!(!e.stats_json().expect("stats").contains(&items[1].key.to_string()));
    e.set_learning_paused(true).expect("pause");
    assert!(
        !e.record(items[1].key, "term", Source::Typed, 0, t + 60.0)
            .expect("record")
    );
    pick(&e, &items[1], "term", 2, &mut t);
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term", "paused");
    e.set_learning_paused(false).expect("resume");
    pick(&e, &items[1], "term", 2, &mut t);
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    e.reset_learning().expect("reset");
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term");
    let mut out = Vec::new();
    e.suggestions(&mut out).expect("suggestions");
    assert!(out.is_empty());
}

#[test]
fn item_flags_opt_out_of_suggestions_and_learning() {
    let quiet = Item {
        flags: flags::NO_SUGGEST,
        ..command("Empty Trash")
    };
    let secret = Item {
        flags: flags::NO_LEARN,
        ..command("Generate Password")
    };
    let items = vec![quiet.clone(), secret.clone()];
    let e = engine(items);
    e.record(quiet.key, "", Source::Suggestion, 0, T0 + 1.0)
        .expect("record");
    assert!(!e.record(secret.key, "gen", Source::Typed, 0, T0 + 2.0).expect("record"));
    let mut out = Vec::new();
    e.suggestions(&mut out).expect("suggestions");
    assert!(out.is_empty());
}

#[test]
fn catalog_changes_reset_narrowing() {
    let items = vec![app("Safari"), app("Slack")];
    let e = engine(items.clone());
    let mut s = Session::new();
    assert_eq!(titles(&e, &mut s, "sa", &items)[0], "Safari");
    let sax = command("Saxophone Tuner");
    e.upsert(2, sax.clone()).expect("upsert");
    let hits = e.query(&mut s, "sax", 10).expect("query");
    assert_eq!(hits[0].key, sax.key, "a stale narrowing set would miss the new item");
    e.remove(sax.key).expect("remove");
    assert!(
        e.query(&mut s, "sax", 10)
            .expect("query")
            .iter()
            .all(|h| h.key != sax.key)
    );
    e.replace_source(1, vec![app("Mail")]).expect("replace");
    assert_eq!(e.len().expect("len"), 1);
}

#[test]
fn statistics_name_items_rows_and_weights() {
    let items = vec![app("Terminal"), app("Safari")];
    let e = engine(items.clone());
    let mut t = T0;
    pick(&e, &items[0], "ter", 2, &mut t);
    e.seed(items[1].key, 0.3, T0 - 86_400.0).expect("seed");
    let stats = e.stats_json().expect("stats");
    for needle in [
        "\"paused\":false",
        "\"catalog\":{\"items\":2,\"sources\":1}",
        "\"seeds\":1",
        "\"typed\":2",
        "\"query\":\"te\"",
        "\"query\":\"ter\"",
        "\"title\":\"Terminal\"",
        "\"name\":\"frecency 3 d\"",
        "\"name\":\"frontmost\"",
    ] {
        assert!(stats.contains(needle), "{needle} in {stats}");
    }
    assert!(stats.starts_with('{') && stats.ends_with('}'));
    let depth = stats.chars().fold(0i32, |d, c| match c {
        '{' | '[' => d + 1,
        '}' | ']' => d - 1,
        _ => d,
    });
    assert_eq!(depth, 0);
}

#[test]
fn kinds_reorder_within_a_tier() {
    let items = vec![
        Item {
            kind: kind::CONTACT,
            ..command("Mara Smith")
        },
        app("Mail Assistant"),
    ];
    let e = engine(items.clone());
    let mut s = Session::new();
    // Both are prefix matches for "ma"; the app kind prior outweighs the shorter title.
    assert_eq!(titles(&e, &mut s, "ma", &items)[0], "Mail Assistant");
}
