//! What the learning inspector reads: the summary numbers, and the text of shorter learned
//! queries after a longer one is forgotten, live and after a restart.

use crate::fixtures::{T0, app, context, engine, pick, temp_dir};
use slick_engine::{Engine, EngineParams, StoreParams};

/// The query texts of the affinity rows in the statistics, in order.
fn rows(e: &Engine) -> Vec<String> {
    let json = e.stats_json().expect("stats");
    let affinity = &json[json.find("\"affinity\"").expect("affinity")..];
    let affinity = &affinity[..affinity.find("\"model\"").expect("model")];
    affinity
        .split("\"query\":\"")
        .skip(1)
        .map(|s| s[..s.find('"').expect("end of text")].to_string())
        .collect()
}

#[test]
fn shorter_queries_keep_their_text_after_a_longer_one_is_forgotten() {
    let term = app("Terminal");
    let tea = app("Tea Timer");
    let e = engine(vec![term.clone(), tea.clone()]);
    let mut t = T0;
    pick(&e, &term, "term", 2, &mut t);
    assert_eq!(rows(&e), ["t", "te", "ter", "term"]);
    assert!(e.forget_query("term").expect("forget"));
    assert_eq!(
        rows(&e),
        ["t", "te", "ter"],
        "the prefixes still rank, so they stay listed"
    );
    assert_eq!(e.summary().expect("summary").queries, 3);
    // The prefixes can be forgotten one by one.
    assert!(e.forget_query("ter").expect("forget"));
    assert_eq!(rows(&e), ["t", "te"]);
    // A text another query still names needs no new definition.
    pick(&e, &tea, "tea", 1, &mut t);
    pick(&e, &term, "term", 1, &mut t);
    assert!(e.forget_query("term").expect("forget"));
    assert_eq!(rows(&e), ["t", "te", "tea", "ter"]);
}

#[test]
fn the_names_survive_a_restart_from_the_log_and_from_a_snapshot() {
    for snapshot_every in [1_000, 3] {
        let dir = temp_dir("inspector-restart");
        let params = || EngineParams {
            store: StoreParams {
                snapshot_every,
                ..StoreParams::default()
            },
            ..EngineParams::default()
        };
        let term = app("Terminal");
        let before = {
            let e = Engine::open(&dir, params()).expect("open");
            e.replace_source(1, vec![term.clone()]).expect("catalog");
            e.set_context(context(T0, 0)).expect("context");
            let mut t = T0;
            pick(&e, &term, "terminal", 4, &mut t);
            assert!(e.forget_query("terminal").expect("forget"));
            pick(&e, &term, "x", 4, &mut t);
            e.flush();
            (rows(&e), e.summary().expect("summary"))
        };
        assert_eq!(before.0, ["t", "te", "ter", "term", "termi", "termin", "termina", "x"]);
        let e = Engine::open(&dir, params()).expect("reopen");
        assert_eq!(
            (rows(&e), e.summary().expect("summary")),
            before,
            "every {snapshot_every}"
        );
        drop(e);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn the_summary_counts_items_and_the_first_event() {
    let a = app("Alpha");
    let b = app("Beta");
    let e = engine(vec![a.clone(), b.clone()]);
    let empty = e.summary().expect("summary");
    assert_eq!(
        (empty.events, empty.items, empty.queries, empty.first_event),
        (0, 0, 0, None)
    );
    e.seed(b.key, 0.3, T0).expect("seed");
    assert_eq!(e.summary().expect("summary").items, 0, "a seed is not a run");
    let mut t = T0;
    pick(&e, &a, "al", 2, &mut t);
    let first = T0 + 60.0;
    pick(&e, &b, "be", 1, &mut t);
    let s = e.summary().expect("summary");
    assert_eq!((s.events, s.items, s.queries), (3, 2, 4));
    let at = s.first_event.expect("a first event");
    assert!((at - first).abs() < 61.0, "{at} against {first}: minute resolution");
    let json = e.stats_json().expect("stats");
    assert!(
        json.contains("\"first_event\":") && json.contains("\"items\":2"),
        "{json}"
    );
    // Undo and forget keep it exact.
    assert!(e.undo(b.key, t + 1.0).expect("undo"));
    assert_eq!(e.summary().expect("summary").items, 1);
    e.forget(a.key).expect("forget");
    let s = e.summary().expect("summary");
    assert_eq!((s.items, s.first_event), (0, None));
    pick(&e, &b, "be", 1, &mut t);
    let s = e.summary().expect("summary");
    assert_eq!(s.items, 1);
    assert!(
        s.first_event.expect("first") > first + 100.0,
        "the oldest run left is the new one"
    );
    e.reset_learning().expect("reset");
    assert_eq!(e.summary().expect("summary"), empty);
}
