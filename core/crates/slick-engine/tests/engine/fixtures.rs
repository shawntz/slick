//! Synthetic catalogs and helpers shared by the engine tests.

use slick_engine::{Context, Engine, EngineError, EngineParams, Item, Session, Source, key_of, kind};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

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

/// Opens an engine on `dir`, waiting while the directory's lock is still held.
///
/// A test that reopens a directory right after dropping its engine can meet the lock held for a
/// moment longer. The tests of this binary run together, and one of them starts a child process. A
/// child holds a copy of every descriptor open in this process, the lock file's among them, until
/// its exec closes them, and the lock is released only then. On a machine that has never run this
/// binary the exec takes long enough to see. So `WouldBlock` is tried again until the lock is free,
/// for ten seconds at most, and any other error fails at once.
pub fn open_engine(dir: &Path, params: EngineParams) -> Engine {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match Engine::open(dir, params.clone()) {
            Ok(engine) => return engine,
            Err(EngineError::Io(e)) if e.kind() == ErrorKind::WouldBlock && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(2));
            }
            Err(e) => panic!("open: {e:?}"),
        }
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
