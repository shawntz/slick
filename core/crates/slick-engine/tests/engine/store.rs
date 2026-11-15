//! The store: a log that stays bounded through compaction, recovery from a crash at every step of
//! a compaction, and forgetting one query's row across restarts.

use crate::fixtures::{T0, app, context, key, temp_dir};
use slick_engine::{Engine, EngineParams, Item, Session, Source, StoreParams, hit_flags};
use std::fs;
use std::path::Path;

const LOG: &str = "events.log";
const LOG_TMP: &str = "events.tmp";
const LOG_LOST: &str = "events.unreadable.log";
const SNAPSHOT: &str = "snapshot.bin";
const SNAPSHOT_PREV: &str = "snapshot.prev.bin";
const SNAPSHOT_TMP: &str = "snapshot.tmp";

/// Snapshots every 40 executions and compaction once 300 records are covered, so a few thousand
/// executions compact the log many times.
fn small(compact: bool) -> EngineParams {
    EngineParams {
        store: StoreParams {
            snapshot_every: 40,
            compact_after: if compact { 300 } else { u64::MAX },
        },
        ..EngineParams::default()
    }
}

fn items() -> Vec<Item> {
    ["Term", "Terminal", "Xcode", "Safari", "Notes", "Mail", "Maps"]
        .iter()
        .map(|t| app(t))
        .collect()
}

/// The learning state as the inspector shows it, minus the fields that depend on the catalog.
fn state(e: &Engine) -> String {
    let json = e.stats_json().expect("stats");
    json[json.find("\"counts\"").expect("counts")..].to_string()
}

fn events(e: &Engine) -> u64 {
    let json = e.stats_json().expect("stats");
    let at = json.find("\"events\":").expect("events field") + 9;
    json[at..]
        .split(|c: char| !c.is_ascii_digit())
        .next()
        .and_then(|n| n.parse().ok())
        .expect("number")
}

/// `n` typed executions over the items and a handful of queries, with an undo, a forgotten item
/// and a forgotten query now and then, so every record kind is in the log.
fn history(e: &Engine, n: usize) {
    let items = items();
    let queries = ["term", "t", "x", "saf", "notes", "ma", "m"];
    let mut t = T0;
    for k in 0..n {
        t += 45.0;
        let item = &items[(k * 7 + k / 3) % items.len()];
        e.record(item.key, queries[k % queries.len()], Source::Typed, 0, t)
            .expect("record");
        if k % 97 == 5 {
            e.undo(item.key, t + 1.0).expect("undo");
        }
        if k % 501 == 400 {
            e.forget(items[k % items.len()].key).expect("forget");
        }
        if k % 733 == 700 {
            e.forget_query(queries[k % queries.len()]).expect("forget query");
        }
    }
}

fn open(dir: &Path, params: EngineParams) -> Engine {
    let e = Engine::open(dir, params).expect("open");
    e.replace_source(1, items()).expect("catalog");
    e
}

fn copy(from: &Path, to: &Path, files: &[&str]) {
    fs::create_dir_all(to).expect("dir");
    for f in files {
        if from.join(f).exists() {
            fs::copy(from.join(f), to.join(f)).expect("copy");
        }
    }
}

#[test]
fn the_log_stays_bounded_and_a_restart_changes_nothing() {
    let dir = temp_dir("bounded");
    let before = {
        let e = open(&dir, small(true));
        history(&e, 4_000);
        e.flush();
        state(&e)
    };
    let len = fs::metadata(dir.join(LOG)).expect("log").len();
    // About 4,000 executions write more than 4,000 records. The log keeps at most the compaction
    // threshold past the previous snapshot plus two snapshot intervals, and a header.
    assert!(len <= 32 * (1 + 300 + 3 * 2 * 40 + 64), "log {len} bytes");
    let e = open(&dir, small(true));
    assert_eq!(state(&e), before, "a restart after compactions");
    assert_eq!(events(&e), 4_000 - 4_000 / 97 - 1);
}

/// A compaction writes the snapshot, moves the old one aside, writes `events.tmp` and renames it
/// over the log. Each file set a crash can leave behind recovers to the same state.
#[test]
fn every_crash_point_of_a_compaction_recovers() {
    // The same history twice: compacted, and with the whole log kept.
    let compacted = temp_dir("crash-compacted");
    let whole = temp_dir("crash-whole");
    for (dir, compact) in [(&compacted, true), (&whole, false)] {
        let e = open(dir, small(compact));
        history(&e, 2_000);
        e.flush();
        // Leave the files as a crash would, without the snapshot a clean close writes.
        std::mem::forget(e);
    }
    let compacted_len = fs::metadata(compacted.join(LOG)).expect("log").len();
    let whole_len = fs::metadata(whole.join(LOG)).expect("log").len();
    assert!(
        compacted_len * 3 < whole_len,
        "compaction ran: {compacted_len} of {whole_len} bytes"
    );
    let all = [LOG, SNAPSHOT, SNAPSHOT_PREV];
    let reference = {
        let dir = temp_dir("crash-reference");
        copy(&compacted, &dir, &all);
        state(&open(&dir, small(true)))
    };
    assert_eq!(
        reference,
        {
            let dir = temp_dir("crash-whole-copy");
            copy(&whole, &dir, &[LOG]);
            state(&open(&dir, small(false)))
        },
        "the compacted files and a full replay agree"
    );

    // Before the snapshot rename, or before the log rename: half-written temporaries.
    let dir = temp_dir("crash-temporaries");
    copy(&compacted, &dir, &all);
    fs::write(dir.join(SNAPSHOT_TMP), b"VTRS half a snapshot").expect("tmp");
    fs::write(dir.join(LOG_TMP), vec![0xA5; 100]).expect("tmp");
    assert_eq!(state(&open(&dir, small(true))), reference, "temporaries");
    assert!(!dir.join(SNAPSHOT_TMP).exists() && !dir.join(LOG_TMP).exists());

    // Between moving the old snapshot aside and renaming the new one in.
    let dir = temp_dir("crash-between-renames");
    copy(&compacted, &dir, &[LOG, SNAPSHOT_PREV]);
    assert_eq!(state(&open(&dir, small(true))), reference, "only the previous snapshot");

    // Before the log rename: the new snapshots with the old, whole log.
    let dir = temp_dir("crash-before-log-rename");
    copy(&compacted, &dir, &[SNAPSHOT, SNAPSHOT_PREV]);
    copy(&whole, &dir, &[LOG]);
    assert_eq!(state(&open(&dir, small(true))), reference, "old log, new snapshots");

    // A damaged newest snapshot falls back to the previous one, which covers the log's start.
    let dir = temp_dir("crash-damaged-snapshot");
    copy(&compacted, &dir, &all);
    let mut bytes = fs::read(dir.join(SNAPSHOT)).expect("snapshot");
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0x40;
    fs::write(dir.join(SNAPSHOT), &bytes).expect("write");
    assert_eq!(state(&open(&dir, small(true))), reference, "damaged newest snapshot");

    // Neither snapshot readable: a compacted log cannot be replayed alone. The engine opens empty
    // and keeps the log aside instead of failing or deleting it.
    let dir = temp_dir("crash-no-snapshot");
    copy(&compacted, &dir, &[LOG]);
    let e = open(&dir, small(true));
    assert_eq!(events(&e), 0);
    assert!(dir.join(LOG_LOST).exists());
    history(&e, 50);
    drop(e);
    assert_eq!(events(&open(&dir, small(true))), 50 - 1, "it learns again from there");
}

#[test]
fn a_forgotten_query_stays_forgotten_after_a_restart() {
    let dir = temp_dir("forget-query");
    let items = items();
    let (terminal, term) = (&items[1], &items[0]);
    let learned = |e: &Engine, q: &str| {
        e.query(&mut Session::new(), q, 10)
            .expect("query")
            .iter()
            .any(|h| h.flags & (hit_flags::LEARNED | hit_flags::AFFINITY) != 0)
    };
    {
        let e = open(&dir, EngineParams::default());
        e.set_context(context(T0 + 600.0, 0)).expect("context");
        for k in 0..3 {
            e.record(terminal.key, "terminal", Source::Typed, 0, T0 + 60.0 * k as f64)
                .expect("record");
        }
        assert!(learned(&e, "term") && learned(&e, "terminal"));
        assert!(e.forget_query("Terminal").expect("forget"), "folded like a typed query");
        assert!(!e.forget_query("terminal").expect("forget"), "already gone");
        assert!(!e.forget_query("never typed").expect("forget"));
        assert!(!learned(&e, "terminal"), "typing it ranks by text again");
        assert!(learned(&e, "term"), "a shorter query keeps its own learning");
        assert!(!e.stats_json().expect("stats").contains("\"query\":\"terminal\""));
    }
    for drop_snapshots in [false, true] {
        if drop_snapshots {
            let _ = fs::remove_file(dir.join(SNAPSHOT));
            let _ = fs::remove_file(dir.join(SNAPSHOT_PREV));
        }
        let e = open(&dir, EngineParams::default());
        e.set_context(context(T0 + 600.0, 0)).expect("context");
        assert!(!learned(&e, "terminal"), "after a restart (log only: {drop_snapshots})");
        assert!(learned(&e, "term"));
        assert_eq!(
            e.query(&mut Session::new(), "term", 1).expect("query")[0].key,
            terminal.key
        );
    }
    assert_ne!(term.key, key("app:Terminal"));
}
