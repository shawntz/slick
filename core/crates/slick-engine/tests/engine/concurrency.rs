//! One engine used from many threads at once: queries on every thread while others replace
//! sources, record executions, change the context and read statistics. Nothing may deadlock,
//! panic or return a hit that is not in the catalog.

use crate::fixtures::{T0, context, key};
use slick_engine::{Engine, EngineParams, Item, Session, Source, kind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

/// Two catalogs with disjoint keys, swapped in and out of source 1. Source 2 never changes.
fn generation(tag: &str, n: usize) -> Vec<Item> {
    (0..n)
        .map(|i| Item {
            key: key(&format!("gen:{tag}:{i}")),
            title: format!("Item {tag} {i} Tool"),
            kind: kind::COMMAND,
            ..Item::default()
        })
        .collect()
}

fn stable() -> Vec<Item> {
    ["Terminal", "Safari", "Settings", "Stocks", "Notes"]
        .iter()
        .map(|t| Item {
            key: key(&format!("app:{t}")),
            title: t.to_string(),
            kind: kind::APP,
            ..Item::default()
        })
        .collect()
}

/// Runs `work` on a helper thread and fails the test when it does not finish in time, which is
/// how a deadlock shows up.
fn within(limit: Duration, work: impl FnOnce() + Send + 'static) {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        work();
        let _ = tx.send(());
    });
    match rx.recv_timeout(limit) {
        Ok(()) => {}
        Err(mpsc::RecvTimeoutError::Timeout) => panic!("the workload did not finish in {limit:?}: deadlock"),
        Err(mpsc::RecvTimeoutError::Disconnected) => panic!("a worker thread panicked"),
    }
}

#[test]
fn queries_catalog_changes_learning_and_statistics_run_together() {
    within(Duration::from_secs(60), || {
        let engine = Arc::new(Engine::in_memory(EngineParams::default()));
        let (a, b) = (generation("a", 400), generation("b", 300));
        engine.replace_source(1, a.clone()).expect("catalog");
        engine.replace_source(2, stable()).expect("catalog");
        let valid: std::collections::HashSet<u64> = a.iter().chain(&b).chain(&stable()).map(|i| i.key).collect();
        let valid = Arc::new(valid);
        let stop = Arc::new(AtomicBool::new(false));
        let start = Arc::new(Barrier::new(8));
        let mut workers = Vec::new();

        for w in 0..4 {
            let (engine, valid, stop, start) = (engine.clone(), valid.clone(), stop.clone(), start.clone());
            workers.push(thread::spawn(move || {
                let mut session = Session::new();
                let queries = [
                    "i", "it", "ite", "item a", "item b 1", "t", "te", "ter", "term", "s", "sa",
                ];
                start.wait();
                let mut n = 0usize;
                while !stop.load(Ordering::Relaxed) {
                    let q = queries[(n + w) % queries.len()];
                    let hits = engine.query(&mut session, q, 20).expect("query").to_vec();
                    let mut seen = std::collections::HashSet::new();
                    for pair in hits.windows(2) {
                        assert!(pair[0].rank >= pair[1].rank, "{q}: hits out of order");
                    }
                    for h in &hits {
                        assert!(valid.contains(&h.key), "{q}: unknown key");
                        assert!(seen.insert(h.key), "{q}: duplicate hit");
                        let _ = engine.ranges(&mut session, h.key).expect("ranges");
                    }
                    let _ = engine.completion(&mut session).expect("completion");
                    if n.is_multiple_of(7) {
                        session.reset();
                    }
                    n += 1;
                }
            }));
        }
        {
            let (engine, stop, start) = (engine.clone(), stop.clone(), start.clone());
            workers.push(thread::spawn(move || {
                start.wait();
                let mut flip = false;
                while !stop.load(Ordering::Relaxed) {
                    let next = if flip { a.clone() } else { b.clone() };
                    engine.replace_source(1, next).expect("replace");
                    flip = !flip;
                }
            }));
        }
        {
            let (engine, stop, start) = (engine.clone(), stop.clone(), start.clone());
            workers.push(thread::spawn(move || {
                let terminal = key("app:Terminal");
                let mut t = T0;
                start.wait();
                while !stop.load(Ordering::Relaxed) {
                    t += 30.0;
                    engine.record(terminal, "term", Source::Typed, 0, t).expect("record");
                    engine.set_context(context(t, 0)).expect("context");
                }
            }));
        }
        {
            let (engine, stop, start) = (engine.clone(), stop.clone(), start.clone());
            workers.push(thread::spawn(move || {
                start.wait();
                while !stop.load(Ordering::Relaxed) {
                    let json = engine.stats_json().expect("stats");
                    assert!(json.starts_with('{') && json.ends_with('}'));
                }
            }));
        }
        start.wait();
        let began = Instant::now();
        while began.elapsed() < Duration::from_millis(1500) {
            thread::sleep(Duration::from_millis(50));
        }
        stop.store(true, Ordering::Relaxed);
        for w in workers {
            w.join().expect("worker");
        }
        let n = engine.len().expect("len");
        assert!(n == 5 + 400 || n == 5 + 300, "{n} items");
    });
}
