//! Synthetic catalogs and helpers shared by the engine tests.

use slick_engine::{Context, Engine, EngineParams, Item, Session, Source, key_of, kind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

/// Unix time of a fixed Monday morning in 2026.
pub const T0: f64 = 1_780_000_000.0;

pub fn key(id: &str) -> u64 {
    key_of(id.as_bytes())
}

pub fn app(title: &str) -> Item {
    Item {
        key: key(&format!("app:{title}")),
        title: title.into(),
        kind: kind::APP,
        ..Item::default()
    }
}

pub fn command(title: &str) -> Item {
    Item {
        key: key(&format!("cmd:{title}")),
        title: title.into(),
        kind: kind::COMMAND,
        ..Item::default()
    }
}

pub fn engine(items: Vec<Item>) -> Engine {
    let e = Engine::in_memory(EngineParams::default());
    e.replace_source(1, items).expect("catalog");
    e.set_context(context(T0, 0)).expect("context");
    e
}

pub fn context(now: f64, frontmost: u64) -> Context {
    Context {
        now,
        hour: 9,
        weekday: 0,
        frontmost,
        display_count: 1,
        ..Context::default()
    }
}

/// Titles of the hits for `q`, best first.
pub fn titles(e: &Engine, s: &mut Session, q: &str, items: &[Item]) -> Vec<String> {
    let hits = e.query(s, q, 20).expect("query");
    hits.iter()
        .map(|h| {
            items
                .iter()
                .find(|i| i.key == h.key)
                .map_or("?".into(), |i| i.title.clone())
        })
        .collect()
}

/// Records that `item` ran after typing `q`, `n` times one minute apart, starting at `*t`.
pub fn pick(e: &Engine, item: &Item, q: &str, n: usize, t: &mut f64) {
    for _ in 0..n {
        *t += 60.0;
        e.record(item.key, q, Source::Typed, 0, *t).expect("record");
    }
}

/// A fresh directory under Cargo's temporary directory for this test binary.
pub fn temp_dir(name: &str) -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("slick-engine-tests")
        .join(format!(
            "{name}-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}
