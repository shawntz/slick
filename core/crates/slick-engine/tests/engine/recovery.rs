//! Persistence under attack: a process killed mid-write, a log cut at every byte of its last
//! record, damaged snapshots, two engines on one directory, and startup time over a long history.
//! Opening must never fail on damaged data and must always rebuild a consistent state.

use crate::fixtures::{T0, app, context, key, temp_dir};
use slick_engine::{Engine, EngineParams, Item, Session, Source};
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const LOG: &str = "events.log";
const SNAPSHOT: &str = "snapshot.bin";
const SNAPSHOT_PREV: &str = "snapshot.prev.bin";

fn open(dir: &Path) -> Engine {
    Engine::open(dir, EngineParams::default()).expect("open never fails on damaged data")
}

fn items() -> Vec<Item> {
    ["Term", "Terminal", "Xcode", "Safari", "Notes"]
        .iter()
        .map(|t| app(t))
        .collect()
}

/// Events recorded so far, read from the statistics.
fn events(e: &Engine) -> u64 {
    let json = e.stats_json().expect("stats");
    let at = json.find("\"events\":").expect("events field") + 9;
    json[at..]
        .split(|c: char| !c.is_ascii_digit())
        .next()
        .and_then(|n| n.parse().ok())
        .expect("number")
}

/// Records `n` typed executions spread over the items and a few queries.
fn train(e: &Engine, n: usize, t: &mut f64) {
    let items = items();
    let queries = ["term", "t", "x", "saf", "notes"];
    for k in 0..n {
        *t += 45.0;
        let item = &items[(k * 7 + k / 3) % items.len()];
        e.record(item.key, queries[k % queries.len()], Source::Typed, 0, *t)
            .expect("record");
    }
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("dir");
    for f in [LOG, SNAPSHOT, SNAPSHOT_PREV] {
        if from.join(f).exists() {
            fs::copy(from.join(f), to.join(f)).expect("copy");
        }
    }
}

/// The learning state as the inspector shows it, minus the fields that depend on the catalog.
fn state(e: &Engine) -> String {
    let json = e.stats_json().expect("stats");
    json[json.find("\"counts\"").expect("counts")..].to_string()
}

#[test]
fn a_log_cut_at_every_byte_of_its_last_record_recovers() {
    let dir = temp_dir("cut");
    let mut t = T0;
    let full = {
        let e = open(&dir);
        e.replace_source(1, items()).expect("catalog");
        train(&e, 40, &mut t);
        e.flush();
        events(&e)
    };
    let len = fs::metadata(dir.join(LOG)).expect("log").len();
    assert_eq!(len % 32, 0);
    for keep_snapshot in [false, true] {
        for cut in len - 32..len {
            let copy = temp_dir("cut-copy");
            copy_dir(&dir, &copy);
            if !keep_snapshot {
                fs::remove_file(copy.join(SNAPSHOT)).expect("remove snapshot");
            }
            fs::OpenOptions::new()
                .write(true)
                .open(copy.join(LOG))
                .and_then(|f| f.set_len(cut))
                .expect("cut");
            let e = open(&copy);
            assert_eq!(fs::metadata(copy.join(LOG)).expect("log").len(), len - 32, "cut {cut}");
            let n = events(&e);
            // The last record is an event: without a snapshot it is lost; a snapshot that covers
            // it keeps it.
            let want = if keep_snapshot { full } else { full - 1 };
            assert_eq!(n, want, "cut {cut} snapshot {keep_snapshot}");
            // The engine keeps working and a second restart sees the same state.
            e.record(key("app:Notes"), "n", Source::Typed, 0, t + 60.0)
                .expect("record");
            let before = state(&e);
            drop(e);
            assert_eq!(state(&open(&copy)), before, "cut {cut}: restart after recovery");
        }
    }
}

#[test]
fn every_kind_of_snapshot_damage_falls_back_to_the_log() {
    let dir = temp_dir("snapshot-damage");
    let mut t = T0;
    {
        let e = open(&dir);
        e.replace_source(1, items()).expect("catalog");
        train(&e, 120, &mut t);
    }
    let good = fs::read(dir.join(SNAPSHOT)).expect("snapshot");
    let reference = {
        let copy = temp_dir("snapshot-reference");
        copy_dir(&dir, &copy);
        fs::remove_file(copy.join(SNAPSHOT)).expect("remove");
        state(&open(&copy))
    };
    let mut damaged: Vec<(String, Vec<u8>)> = vec![
        ("empty".into(), Vec::new()),
        ("magic only".into(), b"VTRS".to_vec()),
        ("truncated".into(), good[..good.len() / 2].to_vec()),
        ("one byte short".into(), good[..good.len() - 1].to_vec()),
        (
            "garbage".into(),
            (0..4096u32)
                .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
                .collect(),
        ),
        ("all ones".into(), vec![0xFF; good.len()]),
    ];
    for at in [4, 8, 16, 17, 20, 40, good.len() / 3, good.len() / 2, good.len() - 5] {
        let mut b = good.clone();
        b[at] ^= 0x5A;
        damaged.push((format!("flip at {at}"), b));
    }
    // A length field claiming far more entries than the file holds.
    let mut b = good.clone();
    b[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    damaged.push(("huge length".into(), b));
    for (name, bytes) in damaged {
        let copy = temp_dir("snapshot-copy");
        copy_dir(&dir, &copy);
        fs::write(copy.join(SNAPSHOT), &bytes).expect("write");
        let e = open(&copy);
        assert_eq!(state(&e), reference, "{name}: the log rebuilds the same state");
    }
}

/// The child half of `a_process_killed_mid_write_recovers`: records as fast as it can until the
/// parent kills it. Does nothing unless the parent set the directory.
#[test]
#[ignore = "run by a_process_killed_mid_write_recovers in a child process"]
fn child_records_until_killed() {
    let Ok(dir) = std::env::var("SLICK_TEST_KILL_DIR") else {
        return;
    };
    let e = open(Path::new(&dir));
    e.replace_source(1, items()).expect("catalog");
    let mut t = T0 + 86_400.0 * 30.0;
    loop {
        train(&e, 50, &mut t);
        e.flush();
    }
}

#[test]
fn a_process_killed_mid_write_recovers() {
    let exe = std::env::current_exe().expect("test binary");
    let dir = temp_dir("killed");
    let mut last = 0;
    for (round, wait_ms) in [120u64, 200, 310, 450, 75].into_iter().enumerate() {
        let mut child = Command::new(&exe)
            .args([
                "--ignored",
                "--exact",
                "recovery::child_records_until_killed",
                "--test-threads",
                "1",
            ])
            .env("SLICK_TEST_KILL_DIR", &dir)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn child");
        std::thread::sleep(Duration::from_millis(wait_ms));
        child.kill().expect("kill");
        child.wait().expect("reap");
        let e = open(&dir);
        let n = events(&e);
        assert!(n >= last, "round {round}: {n} events after {last}");
        assert_eq!(fs::metadata(dir.join(LOG)).expect("log").len() % 32, 0, "round {round}");
        let before = state(&e);
        drop(e);
        assert_eq!(
            state(&open(&dir)),
            before,
            "round {round}: a clean restart changes nothing"
        );
        last = n;
    }
    assert!(last > 0, "the child recorded something before it was killed");
}

/// Damage inside the part of the log a snapshot already covers costs nothing: the snapshot holds
/// that state, so recovery reads only the records after it and keeps every one of them.
#[test]
fn damage_the_snapshot_covers_loses_no_later_events() {
    let dir = temp_dir("old-damage");
    let mut t = T0;
    {
        let e = open(&dir);
        e.replace_source(1, items()).expect("catalog");
        train(&e, 1_200, &mut t);
    }
    // A crash after 30 more events: the files as they are after a flush, before any snapshot.
    let crashed = temp_dir("old-damage-crashed");
    {
        let e = open(&dir);
        train(&e, 30, &mut t);
        e.flush();
        copy_dir(&dir, &crashed);
    }
    let reference = {
        let copy = temp_dir("old-damage-reference");
        copy_dir(&crashed, &copy);
        let e = open(&copy);
        assert_eq!(events(&e), 1_230);
        state(&e)
    };
    let log = crashed.join(LOG);
    let mut bytes = fs::read(&log).expect("log");
    bytes[32 * 10 + 5] ^= 0x40; // an early record, long covered by the snapshot
    fs::write(&log, &bytes).expect("write");
    let e = open(&crashed);
    assert_eq!(state(&e), reference, "the snapshot state plus every later event");
    assert_eq!(
        fs::metadata(&log).expect("log").len(),
        bytes.len() as u64,
        "nothing truncated"
    );
}

#[test]
fn a_second_engine_on_the_same_directory_is_refused() {
    let dir = temp_dir("two");
    let first = open(&dir);
    first.replace_source(1, items()).expect("catalog");
    let mut t = T0;
    train(&first, 10, &mut t);
    let second = Engine::open(&dir, EngineParams::default());
    assert!(second.is_err(), "two writers would interleave their logs");
    train(&first, 10, &mut t);
    drop(first);
    let reopened = open(&dir);
    assert_eq!(events(&reopened), 20);
}

/// Startup over a long history: 50,000 executions of 600 distinct items under about 1,000
/// distinct queries, a few minutes apart. Prints the times; `cargo test --release -- --nocapture`
/// gives the numbers worth quoting. The history is written without compaction, so the full replay
/// that a missing snapshot needs is measured on the whole log.
#[test]
fn startup_with_fifty_thousand_events_stays_short() {
    let dir = temp_dir("long-history");
    let mut t = T0;
    let mut params = EngineParams::default();
    params.store.compact_after = u64::MAX;
    let open = |dir: &Path| Engine::open(dir, params.clone()).expect("open");
    {
        let e = open(&dir);
        e.replace_source(1, items()).expect("catalog");
        e.set_context(context(t, 0)).expect("context");
        let letters = b"abcdefghijklmnopqrstuvwxyz";
        for k in 0..50_000usize {
            t += 200.0;
            let item = key(&format!("item:{}", (k * 7919) % 600));
            let q: String = (0..1 + k % 4).map(|i| letters[(k / 7 + i * 5) % 26] as char).collect();
            e.record(item, &q, Source::Typed, 0, t).expect("record");
        }
    }
    let log_bytes = fs::metadata(dir.join(LOG)).expect("log").len();
    let time = |dir: &Path| {
        let start = Instant::now();
        let e = open(dir);
        let elapsed = start.elapsed();
        assert_eq!(events(&e), 50_000);
        elapsed
    };
    let with_snapshot = time(&dir);
    let copy = temp_dir("long-history-no-snapshot");
    copy_dir(&dir, &copy);
    fs::remove_file(copy.join(SNAPSHOT)).expect("remove");
    let _ = fs::remove_file(copy.join(SNAPSHOT_PREV));
    let full_replay = time(&copy);
    println!(
        "startup, 50,000 events, log {} KB: with snapshot {:.1} ms, full replay {:.1} ms",
        log_bytes / 1024,
        with_snapshot.as_secs_f64() * 1e3,
        full_replay.as_secs_f64() * 1e3
    );
    assert!(with_snapshot < Duration::from_secs(2) && full_replay < Duration::from_secs(10));
    let mut s = Session::new();
    let e = open(&dir);
    e.replace_source(1, items()).expect("catalog");
    assert!(!e.query(&mut s, "term", 5).expect("query").is_empty());
}
