//! File index numbers, on trees made under cargo's target temporary folder, never the home
//! folder:
//!
//! - walker throughput on a real tree of about 50,000 entries, `getattrlistbulk` against
//!   `readdir`, one to eight threads;
//! - search over 100,000 synthetic entries on one thread, budget p99 at most 1 ms, and over
//!   1,000,000 on rayon's pool, budget p99 at most 5 ms, cold and typed char by char;
//! - an incremental update of one folder of 100 files, budget under 1 ms, on the real tree and
//!   inside a million-entry index;
//! - how long a reader waits for a snapshot while the writer works;
//! - opening a saved million-entry index; store bytes per entry and resident memory.
//!
//! Search is timed as thread CPU time and wall time of the calling thread at the user-interactive
//! QoS class, in a release build. The bench waits up to ten minutes for the one-minute load
//! average to drop below 5, then measures anyway and prints the load. Set `BENCH_SKIP_WALK=1` to
//! skip the 50,000-file tree, `BENCH_REPS` to change the repetitions and `BENCH_NO_WAIT=1` for a
//! smoke run. Exits with status 1 when a budget is blown.

use slick_files::walk::{self, Method};
use slick_files::{
    Builder, Config, EntryId, Event, FileIndex, Rayon, Rules, SearchOptions, Searcher, Serial, Snapshot, event_flags,
    flags,
};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

unsafe extern "C" {
    /// Darwin: sets the calling thread's quality of service.
    fn pthread_set_qos_class_self_np(qos: u32, relative_priority: i32) -> i32;
}

const USER_INTERACTIVE: u32 = 0x21;
const USER_INITIATED: u32 = 0x19;
const NOW: u32 = 1_763_000_000;

fn set_qos(class: u32) {
    // SAFETY: a Darwin call that changes only the calling thread's scheduling class.
    unsafe {
        pthread_set_qos_class_self_np(class, 0);
    }
}

fn load_average() -> String {
    let mut l = [0f64; 3];
    // SAFETY: `l` has room for the three values requested.
    let n = unsafe { libc::getloadavg(l.as_mut_ptr(), 3) };
    if n < 3 {
        "unknown".into()
    } else {
        format!("{:.2} {:.2} {:.2}", l[0], l[1], l[2])
    }
}

fn one_minute_load() -> f64 {
    let mut l = [0f64; 3];
    // SAFETY: as above.
    let n = unsafe { libc::getloadavg(l.as_mut_ptr(), 3) };
    if n < 1 { 0.0 } else { l[0] }
}

/// CPU time of the calling thread.
fn thread_cpu() -> Duration {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid out parameter for the clock read.
    unsafe {
        libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts);
    }
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

/// Resident and footprint bytes of this process.
fn memory() -> (u64, u64) {
    // SAFETY: the struct is plain data, and zero is a valid value for each field.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is a `rusage_info_v2`, which is what RUSAGE_INFO_V2 writes.
    let r = unsafe {
        libc::proc_pid_rusage(
            std::process::id() as i32,
            libc::RUSAGE_INFO_V2,
            (&mut info as *mut libc::rusage_info_v2).cast(),
        )
    };
    if r != 0 {
        (0, 0)
    } else {
        (info.ri_resident_size, info.ri_phys_footprint)
    }
}

struct Stats {
    name: String,
    samples: Vec<f64>,
    budget: Option<f64>,
}

impl Stats {
    fn new(name: impl Into<String>, budget: Option<f64>) -> Stats {
        Stats {
            name: name.into(),
            samples: Vec::new(),
            budget,
        }
    }

    fn q(&self, q: f64) -> f64 {
        let mut v = self.samples.clone();
        v.sort_by(f64::total_cmp);
        if v.is_empty() {
            return 0.0;
        }
        v[((v.len() - 1) as f64 * q).round() as usize]
    }

    /// Prints one line in µs; returns false when the p99 is over budget.
    fn report(&self) -> bool {
        let p99 = self.q(0.99);
        let ok = self.budget.is_none_or(|b| p99 <= b);
        println!(
            "| {} | {:.1} | {:.1} | {:.1} | {} | {} | {} |",
            self.name,
            self.q(0.5),
            p99,
            self.q(1.0),
            self.samples.len(),
            self.budget.map_or("-".to_string(), |b| format!("{b:.0}")),
            if self.budget.is_none() {
                "-"
            } else if ok {
                "pass"
            } else {
                "FAIL"
            }
        );
        ok
    }
}

fn table_header() {
    println!("| what | p50 µs | p99 µs | max µs | n | budget µs | result |");
    println!("|---|---|---|---|---|---|---|");
}

// ---- synthetic corpus ----

const WORDS: &[&str] = &[
    "report",
    "invoice",
    "budget",
    "notes",
    "meeting",
    "draft",
    "final",
    "resume",
    "letter",
    "photo",
    "img",
    "screenshot",
    "scan",
    "project",
    "src",
    "main",
    "index",
    "test",
    "utils",
    "config",
    "readme",
    "license",
    "docs",
    "design",
    "mockup",
    "logo",
    "icon",
    "video",
    "music",
    "track",
    "album",
    "backup",
    "archive",
    "data",
    "export",
    "results",
    "analysis",
    "chart",
    "slides",
    "presentation",
    "thesis",
    "paper",
    "chapter",
    "todo",
    "plan",
    "schedule",
    "travel",
    "receipt",
    "tax",
    "statement",
    "contract",
    "proposal",
    "spec",
    "api",
    "server",
    "client",
    "model",
    "view",
    "controller",
    "component",
    "button",
    "header",
    "style",
    "theme",
    "image",
    "banner",
    "Quarterly",
    "Summary",
    "Weekly",
    "Review",
    "Interview",
    "Application",
    "Form",
    "Lecture",
    "Homework",
    "Recipe",
    "Garden",
    "Café",
    "Ålesund",
    "日本語",
    "Übersicht",
    "camelCaseThing",
    "HTTPClient",
    "v2",
    "copy",
    "old",
    "new",
];
const EXTS: &[&str] = &[
    "pdf", "docx", "txt", "md", "png", "jpg", "heic", "mov", "mp3", "swift", "rs", "js", "ts", "json", "html", "css",
    "py", "xlsx", "key", "pages", "zip", "csv",
];

fn synth_name(rng: &mut fastrand::Rng, dir: bool) -> String {
    let mut s = String::with_capacity(32);
    let words = 1 + rng.usize(..3);
    for i in 0..words {
        if i > 0 {
            s.push_str([" ", "-", "_", "", "."][rng.usize(..5)]);
        }
        s.push_str(WORDS[rng.usize(..WORDS.len())]);
    }
    match rng.u8(..10) {
        0 => s.push_str(&format!(
            " {}-{:02}-{:02}",
            2015 + rng.u16(..11),
            1 + rng.u8(..12),
            1 + rng.u8(..28)
        )),
        1 | 2 => s.push_str(&rng.u16(..9999).to_string()),
        _ => {}
    }
    if !dir {
        s.push('.');
        s.push_str(EXTS[rng.usize(..EXTS.len())]);
    }
    s
}

/// About `n` synthetic entries below `root`, fed straight into the store. Folders make up about
/// 9 % of entries and nest up to 12 deep.
fn synth(n: usize, root: &[u8], seed: u64) -> (Snapshot, Vec<EntryId>) {
    let mut rng = fastrand::Rng::with_seed(seed);
    let mut b = Builder::with_capacity(n);
    let r = b.root(root, NOW);
    let mut dirs: Vec<(EntryId, u8)> = vec![(r, 0)];
    while b.len() < n {
        // Prefer recent folders so the tree grows deep, like real homes.
        let pick = if rng.u8(..3) == 0 {
            rng.usize(..dirs.len())
        } else {
            dirs.len() - 1 - rng.usize(..dirs.len().min(64))
        };
        let (parent, depth) = dirs[pick];
        let is_dir = rng.u8(..100) < 9 && depth < 12;
        let name = synth_name(&mut rng, is_dir);
        let age = (rng.f64() * rng.f64() * 300_000_000.0) as u32;
        let id = b.add(
            parent,
            name.as_bytes(),
            if is_dir { flags::DIR } else { 0 },
            NOW - age,
            rng.u64(..50_000_000),
        );
        if is_dir {
            dirs.push((id, depth + 1));
        }
    }
    let dir_ids = dirs.iter().map(|d| d.0).collect();
    // Renumber depth first, siblings together, as a walk or a compaction would.
    (compact(b.finish()), dir_ids)
}

/// The snapshot renumbered depth first, the order the walker produces.
fn compact(s: Snapshot) -> Snapshot {
    let mut b = Builder::with_capacity(s.len());
    for (root, path) in s.roots() {
        let Some(info) = s.entry(root) else { continue };
        let r = b.root(path, info.mtime);
        let mut stack = vec![(root, r)];
        while let Some((old, new)) = stack.pop() {
            let mut dirs = Vec::new();
            for c in s.children(old) {
                let Some(e) = s.entry(c) else { continue };
                let id = b.add(new, e.name, e.flags, e.mtime, e.size.unwrap_or(0));
                if e.is_dir() {
                    dirs.push((c, id));
                }
            }
            stack.extend(dirs.into_iter().rev());
        }
    }
    b.finish()
}

const QUERIES: &[&str] = &[
    "a",
    "s",
    "e",
    "r",
    "re",
    "sc",
    "in",
    "ma",
    "co",
    "rea",
    "scr",
    "inv",
    "conf",
    "read",
    "main",
    "repo",
    "readme",
    "screenshot",
    "invoice",
    "budget 2024",
    "docs readme",
    "report pdf",
    ".pdf",
    "src/main",
    "raedme",
    "scrennshot",
    "zzqx",
    "meeting notes",
    "photo jpg",
    "project src",
    "index.js",
    "test",
    "IMG",
    "final draft",
    "x",
    "café",
];

fn opts() -> SearchOptions {
    SearchOptions {
        now: NOW,
        limit: 50,
        ..SearchOptions::default()
    }
}

/// Cold searches without narrowing, and searches typed char by char, over `snap`.
fn bench_search(
    label: &str,
    snap: &Arc<Snapshot>,
    par: &dyn slick_files::ParallelFor,
    reps: usize,
    budget: f64,
) -> bool {
    let o = opts();
    let mut s = Searcher::new();
    let mut out = Vec::new();
    // Warm up.
    for q in QUERIES {
        s.reset();
        s.search(snap, q, &o, par, &mut out);
    }
    let mut cold_wall = Stats::new(format!("{label} cold, wall"), Some(budget));
    let mut cold_cpu = Stats::new(format!("{label} cold, thread CPU"), None);
    let mut typed = Stats::new(format!("{label} typed char by char, wall"), Some(budget));
    let mut worst: Vec<(f64, &str)> = Vec::new();
    for _ in 0..reps {
        for q in QUERIES {
            s.reset();
            let c0 = thread_cpu();
            let t0 = Instant::now();
            s.search(snap, q, &o, par, &mut out);
            let wall = t0.elapsed().as_secs_f64() * 1e6;
            cold_cpu.samples.push((thread_cpu() - c0).as_secs_f64() * 1e6);
            cold_wall.samples.push(wall);
            worst.push((wall, q));
        }
        for q in QUERIES {
            s.reset();
            let mut t = String::new();
            for ch in q.chars() {
                t.push(ch);
                let t0 = Instant::now();
                s.search(snap, &t, &o, par, &mut out);
                typed.samples.push(t0.elapsed().as_secs_f64() * 1e6);
            }
        }
    }
    let ok = cold_wall.report() & typed.report();
    cold_cpu.report();
    worst.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut seen = Vec::new();
    for (t, q) in worst {
        if !seen.iter().any(|(_, x)| *x == q) {
            seen.push((t, q));
        }
        if seen.len() == 5 {
            break;
        }
    }
    println!(
        "\nslowest cold queries ({label}): {}\n",
        seen.iter()
            .map(|(t, q)| format!("{q:?} {t:.0} µs"))
            .collect::<Vec<_>>()
            .join(", ")
    );
    ok
}

// ---- real tree ----

struct Tree(PathBuf);

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A home-like tree: about 50,000 indexed files in about 4,000 folders, plus skipped dependency
/// and hidden folders.
fn make_tree(root: &Path) -> usize {
    let mut rng = fastrand::Rng::with_seed(50);
    let mut made = 0;
    let file = |p: PathBuf, rng: &mut fastrand::Rng| {
        if let Some(d) = p.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(&p, vec![b'x'; rng.usize(0..64)]);
    };
    let modules: Vec<String> = (0..12).map(|_| synth_name(&mut rng, true)).collect();
    for proj in 0..40 {
        let base = root.join(format!("Projects/{}-{proj}", synth_name(&mut rng, true)));
        for i in 0..700 {
            let sub = format!("src/{}/part{}", modules[i % 12], i % 6);
            file(base.join(sub).join(synth_name(&mut rng, false)), &mut rng);
            made += 1;
        }
        for i in 0..80 {
            file(base.join(format!("node_modules/pkg{}/{i}.js", i % 8)), &mut rng);
            file(base.join(format!(".git/objects/{i}")), &mut rng);
        }
    }
    let folders: Vec<String> = (0..60).map(|_| synth_name(&mut rng, true)).collect();
    for i in 0..12_000 {
        let p = root.join(format!("Documents/{}/{}", folders[i % 60], i % 20));
        file(p.join(synth_name(&mut rng, false)), &mut rng);
        made += 1;
    }
    for i in 0..9_000 {
        file(
            root.join(format!("Pictures/{}/{:02}/IMG_{i:05}.heic", 2015 + i % 11, 1 + i % 12)),
            &mut rng,
        );
        made += 1;
    }
    for i in 0..100 {
        file(root.join(format!("inc/file-{i:03}.txt")), &mut rng);
        made += 1;
    }
    made
}

fn bench_walk(root: &Path, reps: usize) {
    let rules = Rules::recommended(None);
    println!("| method | threads | median ms | min ms | entries | dirs | entries/s (median) | n |");
    println!("|---|---|---|---|---|---|---|---|");
    for method in [Method::Bulk, Method::ReaddirStat, Method::Readdir] {
        for threads in [1usize, 4, 8] {
            let mut times = Vec::new();
            let mut last = None;
            for _ in 0..reps {
                if let Ok(s) = walk::measure(root, &rules, threads, method) {
                    times.push(s.elapsed.as_secs_f64() * 1e3);
                    last = Some(s);
                }
            }
            times.sort_by(f64::total_cmp);
            let Some(s) = last else { continue };
            let med = times[times.len() / 2];
            println!(
                "| {method:?} | {threads} | {med:.1} | {:.1} | {} | {} | {:.0} | {} |",
                times[0],
                s.entries,
                s.dirs,
                s.entries as f64 / (med / 1e3),
                times.len()
            );
        }
    }
    println!();
}

fn bench_updates(idx: &FileIndex, dir: &Path, reps: usize, label: &str) -> bool {
    let mut add = Stats::new(format!("{label}: add one file to a 100-file folder"), Some(1_000.0));
    let mut del = Stats::new(format!("{label}: remove it again"), Some(1_000.0));
    let mut touch = Stats::new(format!("{label}: modify one file"), Some(1_000.0));
    for i in 0..reps {
        let p = dir.join(format!("added-{i}.txt"));
        let _ = std::fs::write(&p, b"x");
        let t0 = Instant::now();
        idx.apply(&[Event::new(&p, event_flags::ITEM_CREATED | event_flags::ITEM_IS_FILE)]);
        add.samples.push(t0.elapsed().as_secs_f64() * 1e6);
        let _ = std::fs::remove_file(&p);
        let t0 = Instant::now();
        idx.apply(&[Event::new(&p, event_flags::ITEM_REMOVED | event_flags::ITEM_IS_FILE)]);
        del.samples.push(t0.elapsed().as_secs_f64() * 1e6);
        let f = dir.join(format!("file-{:03}.txt", i % 100));
        let _ = std::fs::write(&f, vec![b'y'; i % 50]);
        let t0 = Instant::now();
        idx.apply(&[Event::new(&f, event_flags::ITEM_MODIFIED | event_flags::ITEM_IS_FILE)]);
        touch.samples.push(t0.elapsed().as_secs_f64() * 1e6);
    }
    add.report() & del.report() & touch.report()
}

/// How long `snapshot()` takes in reader threads while the writer applies updates.
fn bench_reader_wait(idx: &Arc<FileIndex>, dir: &Path, reps: usize) {
    let stop = AtomicBool::new(false);
    let mut waits: Vec<f64> = Vec::new();
    std::thread::scope(|s| {
        let readers: Vec<_> = (0..2)
            .map(|_| {
                s.spawn(|| {
                    set_qos(USER_INTERACTIVE);
                    let mut v = Vec::with_capacity(1 << 20);
                    while !stop.load(Ordering::Relaxed) {
                        let t0 = Instant::now();
                        let snap = idx.snapshot();
                        v.push(t0.elapsed().as_secs_f64() * 1e6);
                        std::hint::black_box(snap.len());
                    }
                    v
                })
            })
            .collect();
        for i in 0..reps {
            let p = dir.join(format!("wait-{i}.txt"));
            let _ = std::fs::write(&p, b"x");
            idx.apply(&[Event::new(&p, event_flags::ITEM_CREATED)]);
            let _ = std::fs::remove_file(&p);
            idx.apply(&[Event::new(&p, event_flags::ITEM_REMOVED)]);
        }
        stop.store(true, Ordering::Relaxed);
        for r in readers {
            if let Ok(v) = r.join() {
                waits.extend(v);
            }
        }
    });
    let mut st = Stats::new("reader snapshot() while the writer updates", None);
    st.samples = waits;
    // The same loop with nothing between the two clock reads: the timer and the scheduler alone.
    let mut base = Stats::new("timer alone, same threads, same writer", None);
    let stop = AtomicBool::new(false);
    std::thread::scope(|s| {
        let readers: Vec<_> = (0..2)
            .map(|_| {
                s.spawn(|| {
                    set_qos(USER_INTERACTIVE);
                    let mut v = Vec::with_capacity(1 << 20);
                    while !stop.load(Ordering::Relaxed) {
                        let t0 = Instant::now();
                        std::hint::black_box(&v);
                        v.push(t0.elapsed().as_secs_f64() * 1e6);
                    }
                    v
                })
            })
            .collect();
        for i in 0..reps {
            let p = dir.join(format!("base-{i}.txt"));
            let _ = std::fs::write(&p, b"x");
            idx.apply(&[Event::new(&p, event_flags::ITEM_CREATED)]);
            let _ = std::fs::remove_file(&p);
            idx.apply(&[Event::new(&p, event_flags::ITEM_REMOVED)]);
        }
        stop.store(true, Ordering::Relaxed);
        for r in readers {
            if let Ok(v) = r.join() {
                base.samples.extend(v);
            }
        }
    });
    table_header();
    st.report();
    base.report();
    println!(
        "\np99.9 / p99.99: snapshot() {:.2} / {:.2} µs, timer alone {:.2} / {:.2} µs\n",
        st.q(0.999),
        st.q(0.9999),
        base.q(0.999),
        base.q(0.9999)
    );
}

/// `BENCH_LOOP=<query>`: repeats one cold search over 100k entries for `BENCH_LOOP_SECS` seconds,
/// for a sampling profiler.
fn profile_loop(q: &str) {
    let secs: u64 = std::env::var("BENCH_LOOP_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(5);
    let (snap, _) = synth(100_000, b"/synthetic/hundred-k", 1);
    let snap = Arc::new(snap);
    let mut s = Searcher::new();
    let mut out = Vec::new();
    let t0 = Instant::now();
    let mut n = 0u64;
    while t0.elapsed() < Duration::from_secs(secs) {
        s.reset();
        s.search(&snap, q, &opts(), &Serial, &mut out);
        n += 1;
    }
    println!(
        "{q:?}: {n} searches, {:.1} µs each, stats {:?}",
        t0.elapsed().as_secs_f64() * 1e6 / n as f64,
        s.stats()
    );
}

/// `BENCH_TYPED=1`: types every query char by char over 100k entries and prints the slowest
/// keystrokes, median of five runs each.
fn profile_typed() {
    let (snap, _) = synth(100_000, b"/synthetic/hundred-k", 1);
    let snap = Arc::new(snap);
    let mut s = Searcher::new();
    let mut out = Vec::new();
    let mut rows: Vec<(f64, String, String)> = Vec::new();
    for q in QUERIES {
        let mut times: Vec<Vec<f64>> = Vec::new();
        let mut stats = Vec::new();
        for _ in 0..5 {
            s.reset();
            let mut t = String::new();
            for (i, ch) in q.chars().enumerate() {
                t.push(ch);
                let t0 = Instant::now();
                s.search(&snap, &t, &opts(), &Serial, &mut out);
                if times.len() <= i {
                    times.push(Vec::new());
                    stats.push(format!("{:?}", s.stats()));
                }
                times[i].push(t0.elapsed().as_secs_f64() * 1e6);
            }
        }
        let mut t = String::new();
        for (i, ch) in q.chars().enumerate() {
            t.push(ch);
            times[i].sort_by(f64::total_cmp);
            rows.push((times[i][2], t.clone(), stats[i].clone()));
        }
    }
    rows.sort_by(|a, b| b.0.total_cmp(&a.0));
    for (us, q, st) in rows.iter().take(15) {
        println!("{us:8.1} µs {q:?} {st}");
    }
}

fn main() {
    set_qos(USER_INTERACTIVE);
    if let Ok(q) = std::env::var("BENCH_LOOP") {
        profile_loop(&q);
        return;
    }
    if std::env::var("BENCH_TYPED").is_ok() {
        profile_typed();
        return;
    }
    let reps: usize = std::env::var("BENCH_REPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10);
    let _ = rayon::ThreadPoolBuilder::new()
        .start_handler(|_| set_qos(USER_INITIATED))
        .build_global();
    // Rule 6: measure when the machine is quiet, or after waiting ten minutes.
    let waited = Instant::now();
    let wait = std::env::var("BENCH_NO_WAIT").is_err();
    while wait && one_minute_load() >= 5.0 && waited.elapsed() < Duration::from_secs(600) {
        std::thread::sleep(Duration::from_secs(15));
    }
    println!(
        "load average {} (waited {:.0} s), rayon threads {}, reps {reps}\n",
        load_average(),
        waited.elapsed().as_secs_f64(),
        rayon::current_num_threads()
    );
    let tmp = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("vf-bench-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&tmp);
    let tmp = std::fs::canonicalize(&tmp).unwrap_or(tmp);
    let cleanup = Tree(tmp.clone());
    let mut ok = true;

    // ---- walker and updates on a real tree ----
    if std::env::var("BENCH_SKIP_WALK").is_err() {
        let home = tmp.join("home");
        let t0 = Instant::now();
        let made = make_tree(&home);
        println!(
            "made a tree of {made} indexed files in {:.1} s\n",
            t0.elapsed().as_secs_f64()
        );
        println!("## walker, load {}\n", load_average());
        bench_walk(&home, 5);
        let (idx, ws) = FileIndex::build(Config::new(vec![home.clone()], Rules::recommended(None)));
        let snap = idx.snapshot();
        println!(
            "index of the real tree: {} entries, built in {:.1} ms, store {:.1} bytes per entry\n",
            snap.len(),
            ws.elapsed.as_secs_f64() * 1e3,
            snap.heap_bytes() as f64 / snap.len() as f64
        );
        println!("## updates on the real tree, load {}\n", load_average());
        table_header();
        ok &= bench_updates(&idx, &home.join("inc"), 200, "50k index");
        println!();
        println!("## search over the real tree, load {}\n", load_average());
        table_header();
        ok &= bench_search("50k real, 1 thread", &snap, &Serial, reps, 1_000.0);
    }

    // ---- 100,000 synthetic entries, one thread ----
    println!("## search, load {}\n", load_average());
    let t0 = Instant::now();
    let (s100, _) = synth(100_000, b"/synthetic/hundred-k", 1);
    let names: usize = s100.entries().iter().map(|(_, e)| e.name.len()).sum();
    println!(
        "100k: built in {:.0} ms, store {:.1} bytes per entry (names average {:.1} bytes)\n",
        t0.elapsed().as_secs_f64() * 1e3,
        s100.heap_bytes() as f64 / s100.len() as f64,
        names as f64 / s100.len() as f64
    );
    let s100 = Arc::new(s100);
    table_header();
    ok &= bench_search("100k, 1 thread", &s100, &Serial, reps, 1_000.0);
    drop(s100);

    // ---- 1,000,000 synthetic entries, parallel ----
    let real_root = tmp.join("million");
    let _ = std::fs::create_dir_all(real_root.join("inc"));
    for i in 0..100 {
        let _ = std::fs::write(real_root.join(format!("inc/file-{i:03}.txt")), b"x");
    }
    let (rss0, _) = memory();
    let t0 = Instant::now();
    let (mut m, _) = synth(1_000_000, real_root.as_os_str().as_bytes(), 2);
    let build_ms = t0.elapsed().as_secs_f64() * 1e3;
    // Graft the real 100-file folder so updates have something on disk to list.
    let config = Config::new(vec![real_root.clone()], Rules::recommended(None));
    m = graft_inc(m, &real_root);
    let (rss1, foot1) = memory();
    let names: usize = m.entries().iter().map(|(_, e)| e.name.len()).sum();
    println!(
        "1M: built in {build_ms:.0} ms, {} entries, store {:.1} bytes per entry (names average {:.1} bytes), resident {:.0} MB (+{:.0} MB), footprint {:.0} MB\n",
        m.len(),
        m.heap_bytes() as f64 / m.len() as f64,
        names as f64 / m.len() as f64,
        rss1 as f64 / 1e6,
        (rss1.saturating_sub(rss0)) as f64 / 1e6,
        foot1 as f64 / 1e6
    );
    let m = Arc::new(m);
    table_header();
    ok &= bench_search("1M, rayon", &m, &Rayon, reps.div_ceil(2), 5_000.0);
    bench_search("1M, 1 thread, for reference", &m, &Serial, 1, f64::INFINITY);

    // ---- updates inside a million-entry index, readers waiting ----
    let idx = Arc::new(FileIndex::from_snapshot(config.clone(), (*m).clone()));
    drop(m);
    println!("## updates inside the 1M index, load {}\n", load_average());
    table_header();
    ok &= bench_updates(&idx, &real_root.join("inc"), 200, "1M index");
    bench_reader_wait(&idx, &real_root.join("inc"), 300);
    println!();

    // ---- open a saved million-entry index ----
    let file = tmp.join("million.idx");
    let t0 = Instant::now();
    if let Err(e) = idx.save(&file, 1) {
        println!("save failed: {e}");
    }
    let save_ms = t0.elapsed().as_secs_f64() * 1e3;
    let size = std::fs::metadata(&file).map_or(0, |m| m.len());
    drop(idx);
    let mut open = Stats::new("open a 1M index file (mmap, checksum, validation)", None);
    let mut first = Stats::new("first search after open, rayon", None);
    for _ in 0..reps.max(5) {
        let t0 = Instant::now();
        let Ok((opened, _)) = FileIndex::open(&file, config.clone()) else {
            println!("open failed");
            break;
        };
        open.samples.push(t0.elapsed().as_secs_f64() * 1e6);
        let snap = opened.snapshot();
        let mut s = Searcher::new();
        let mut out = Vec::new();
        let t0 = Instant::now();
        s.search(&snap, "budget", &opts(), &Rayon, &mut out);
        first.samples.push(t0.elapsed().as_secs_f64() * 1e6);
    }
    println!("## persistence, load {}\n", load_average());
    println!("saved {:.1} MB in {save_ms:.0} ms\n", size as f64 / 1e6);
    table_header();
    open.report();
    first.report();
    let (rss2, foot2) = memory();
    println!(
        "\nresident after the runs {:.0} MB, footprint {:.0} MB",
        rss2 as f64 / 1e6,
        foot2 as f64 / 1e6
    );
    println!("\nload average at the end {}", load_average());
    if !ok {
        println!("\na budget was blown");
        // `exit` skips destructors, so remove the trees first.
        drop(cleanup);
        std::process::exit(1);
    }
}

/// Adds `inc/` with its 100 files from disk below the root of `m`.
fn graft_inc(m: Snapshot, root: &Path) -> Snapshot {
    // Rebuild through a builder: copy every entry, then add the real folder.
    let mut b = Builder::with_capacity(m.len() + 101);
    let Some((old_root, _)) = m.roots().next() else {
        return m;
    };
    let r = b.root(root.as_os_str().as_bytes(), NOW);
    let mut stack = vec![(old_root, r)];
    while let Some((old, new)) = stack.pop() {
        let mut dirs = Vec::new();
        for c in m.children(old) {
            let Some(e) = m.entry(c) else { continue };
            let id = b.add(new, e.name, e.flags, e.mtime, e.size.unwrap_or(0));
            if e.is_dir() {
                dirs.push((c, id));
            }
        }
        stack.extend(dirs.into_iter().rev());
    }
    let inc = b.add(r, b"inc", flags::DIR, NOW, 0);
    for i in 0..100 {
        let p = root.join(format!("inc/file-{i:03}.txt"));
        let meta = std::fs::metadata(&p).ok();
        let mtime = meta
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(NOW, |d| d.as_secs() as u32);
        b.add(
            inc,
            format!("file-{i:03}.txt").as_bytes(),
            0,
            mtime,
            meta.map_or(0, |m| m.len()),
        );
    }
    b.finish()
}
