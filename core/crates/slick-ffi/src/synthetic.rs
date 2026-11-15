//! Synthetic file trees for tests and benchmarks: deterministic names, folders and times, built
//! straight into a snapshot without touching the disk. The words are generic; no real file names.

use slick_files::{Builder, EntryId, Snapshot, flags};

/// The fixed "now" of synthetic trees, Unix seconds.
pub(crate) const NOW: u32 = 1_794_000_000;

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
    "component",
    "button",
    "header",
    "style",
    "theme",
    "Quarterly",
    "Summary",
    "Weekly",
    "Review",
    "Lecture",
    "Homework",
    "Recipe",
    "Garden",
    "Café",
    "Übersicht",
    "日本語",
    "camelCaseThing",
    "HTTPClient",
    "v2",
    "copy",
    "old",
    "new",
];

const EXTS: &[&str] = &[
    "pdf", "docx", "txt", "md", "png", "jpg", "heic", "mov", "mp3", "swift", "rs", "js", "ts", "json", "html", "css",
    "py", "xlsx", "key", "zip", "csv",
];

/// SplitMix64: small, fast and deterministic.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

fn name(rng: &mut Rng, dir: bool, out: &mut String) {
    use std::fmt::Write;
    out.clear();
    let words = 1 + rng.below(3);
    for i in 0..words {
        if i > 0 {
            out.push_str([" ", "-", "_", "", "."][rng.below(5)]);
        }
        out.push_str(WORDS[rng.below(WORDS.len())]);
    }
    match rng.below(10) {
        0 => {
            let _ = write!(
                out,
                " {}-{:02}-{:02}",
                2015 + rng.below(11),
                1 + rng.below(12),
                1 + rng.below(28)
            );
        }
        1 | 2 => {
            let _ = write!(out, "{}", rng.below(9999));
        }
        _ => {}
    }
    if !dir {
        out.push('.');
        out.push_str(EXTS[rng.below(EXTS.len())]);
    }
}

/// About `n` entries below `root`. Folders make up about 9 % of entries and nest up to 12 deep,
/// and the ids follow a depth-first walk, as the walker and a compaction leave them.
pub(crate) fn tree(n: usize, root: &[u8], seed: u64) -> Snapshot {
    let mut rng = Rng(seed);
    let mut b = Builder::with_capacity(n);
    let r = b.root(root, NOW);
    let mut dirs: Vec<(EntryId, u8)> = vec![(r, 0)];
    let mut s = String::with_capacity(64);
    while b.len() < n {
        // Prefer recent folders so the tree grows deep, like a real home folder.
        let pick = if rng.below(3) == 0 {
            rng.below(dirs.len())
        } else {
            dirs.len() - 1 - rng.below(dirs.len().min(64))
        };
        let (parent, depth) = dirs[pick];
        let is_dir = rng.below(100) < 9 && depth < 12;
        name(&mut rng, is_dir, &mut s);
        let age = (rng.unit() * rng.unit() * 300_000_000.0) as u32;
        let size = rng.below(50_000_000) as u64;
        let id = b.add(
            parent,
            s.as_bytes(),
            if is_dir { flags::DIR } else { 0 },
            NOW - age,
            size,
        );
        if is_dir {
            dirs.push((id, depth + 1));
        }
    }
    depth_first(b.finish())
}

/// The snapshot renumbered depth first, siblings together.
fn depth_first(s: Snapshot) -> Snapshot {
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
