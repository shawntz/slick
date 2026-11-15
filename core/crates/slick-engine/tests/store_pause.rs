//! A snapshot never makes a record call wait. Its own test binary, because the pause it sets is
//! global to the process.

#[path = "engine/fixtures.rs"]
#[allow(dead_code, reason = "shared fixtures; this binary uses a few")]
mod fixtures;

use fixtures::{T0, app, temp_dir};
use slick_engine::{Engine, EngineParams, Source, StoreParams, pause_snapshots_for_tests};
use std::time::{Duration, Instant};

#[test]
fn a_slow_snapshot_never_makes_a_record_wait() {
    let dir = temp_dir("slow-snapshot");
    let params = EngineParams {
        store: StoreParams {
            snapshot_every: 10,
            ..StoreParams::default()
        },
        ..EngineParams::default()
    };
    let e = Engine::open(&dir, params).expect("open");
    let items = [app("Term"), app("Terminal"), app("Notes")];
    e.replace_source(1, items.to_vec()).expect("catalog");
    pause_snapshots_for_tests(400);
    let mut t = T0;
    let mut slowest = Duration::ZERO;
    let started = Instant::now();
    // Every tenth record queues a snapshot that takes 400 ms; the records around it go on.
    for k in 0..40 {
        t += 60.0;
        let start = Instant::now();
        e.record(items[k % 3].key, "te", Source::Typed, 0, t).expect("record");
        slowest = slowest.max(start.elapsed());
    }
    let total = started.elapsed();
    // The flush waits for the queued snapshots, which proves they were slow.
    let flushing = Instant::now();
    e.flush();
    let flushed = flushing.elapsed();
    pause_snapshots_for_tests(0);
    let stats = e.stats_json().expect("stats");
    drop(e);
    assert!(stats.contains("\"io_errors\":0"), "{stats}");
    assert!(
        flushed >= Duration::from_millis(400),
        "the snapshots ran, slowly: {flushed:?}"
    );
    assert!(dir.join("snapshot.bin").exists() && dir.join("snapshot.prev.bin").exists());
    assert!(slowest < Duration::from_millis(150), "a record waited {slowest:?}");
    assert!(total < Duration::from_millis(300), "40 records took {total:?}");
}
