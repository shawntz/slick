//! Persistence: the log and the snapshot survive a restart, a corrupt tail is truncated, and a bad
//! snapshot is ignored.

use crate::fixtures::{T0, app, context, open_engine, pick, temp_dir, titles};
use slick_engine::{Engine, EngineParams, Item, Session};
use std::fs;
use std::io::Write;
use std::path::Path;

fn open(dir: &Path, items: &[Item]) -> Engine {
    let e = open_engine(dir, EngineParams::default());
    e.replace_source(1, items.to_vec()).expect("catalog");
    e.set_context(context(T0 + 86_400.0, 0)).expect("context");
    e
}

fn trained(dir: &Path, items: &[Item]) {
    let e = open(dir, items);
    let mut t = T0;
    pick(&e, &items[1], "term", 2, &mut t);
    pick(&e, &items[2], "x", 3, &mut t);
}

fn items() -> Vec<Item> {
    vec![app("Term"), app("Terminal"), app("Xcode")]
}

#[test]
fn learning_survives_a_restart() {
    let dir = temp_dir("restart");
    let items = items();
    trained(&dir, &items);
    assert!(dir.join("snapshot.bin").exists(), "closing writes a snapshot");
    let e = open(&dir, &items);
    let mut s = Session::new();
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    let stats = e.stats_json().expect("stats");
    assert!(stats.contains("\"events\":5"), "{stats}");
    // Without the snapshot, the log alone rebuilds the same state.
    drop(e);
    fs::remove_file(dir.join("snapshot.bin")).expect("remove snapshot");
    let e = open(&dir, &items);
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    assert!(e.stats_json().expect("stats").contains("\"events\":5"));
}

#[test]
fn a_corrupt_tail_is_truncated_and_never_fatal() {
    let dir = temp_dir("corrupt");
    let items = items();
    trained(&dir, &items);
    fs::remove_file(dir.join("snapshot.bin")).expect("remove snapshot");
    let log = dir.join("events.log");
    let good = fs::metadata(&log).expect("log").len();
    let mut f = fs::OpenOptions::new().append(true).open(&log).expect("log");
    f.write_all(&[0xA5; 45]).expect("write garbage");
    drop(f);
    let e = open(&dir, &items);
    assert_eq!(fs::metadata(&log).expect("log").len(), good);
    let mut s = Session::new();
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
    // Damage inside the log keeps the records before it.
    drop(e);
    let mut bytes = fs::read(&log).expect("log");
    let last = bytes.len() - 32;
    bytes[last + 3] ^= 0xFF;
    fs::write(&log, &bytes).expect("write");
    fs::remove_file(dir.join("snapshot.bin")).expect("remove snapshot");
    let e = open(&dir, &items);
    assert_eq!(fs::metadata(&log).expect("log").len(), last as u64);
    assert!(e.stats_json().expect("stats").contains("\"events\":4"));
}

#[test]
fn a_damaged_snapshot_is_ignored() {
    let dir = temp_dir("snapshot");
    let items = items();
    trained(&dir, &items);
    fs::write(dir.join("snapshot.bin"), b"VTRS not a snapshot at all").expect("write");
    let e = open(&dir, &items);
    let mut s = Session::new();
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Terminal");
}

#[test]
fn reset_erases_the_files() {
    let dir = temp_dir("reset");
    let items = items();
    trained(&dir, &items);
    let e = open(&dir, &items);
    e.reset_learning().expect("reset");
    e.flush();
    assert_eq!(fs::metadata(dir.join("events.log")).expect("log").len(), 0);
    assert!(!dir.join("snapshot.bin").exists());
    drop(e);
    let e = open(&dir, &items);
    let mut s = Session::new();
    assert_eq!(titles(&e, &mut s, "term", &items)[0], "Term");
}

#[test]
fn the_data_directory_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp_dir("private");
    trained(&dir, &items());
    for f in ["events.log", "snapshot.bin"] {
        let mode = fs::metadata(dir.join(f)).expect("file").permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{f}");
    }
}
