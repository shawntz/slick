//! Crate-level tests: search against a brute-force reference, and the persistence reader fed
//! damaged files.

mod persist_fuzz;
mod reference;

use crate::store::{Builder, EntryId, Snapshot, flags};

/// Words that synthetic names are made of: plain, camelCase, digits, diacritics, CJK, emoji.
pub(crate) const WORDS: &[&str] = &[
    "docs",
    "readme",
    "report",
    "proj",
    "src",
    "main",
    "notes",
    "screenshot",
    "img",
    "invoice",
    "budget",
    "draft",
    "final",
    "plan",
    "build",
    "test",
    "photo",
    "music",
    "camelCase",
    "HTMLParser",
    "Café",
    "Ålesund",
    "日本語",
    "🎉party",
    "v2",
    "a",
    "x",
    "mode",
    "dark",
    "calendar",
    "resume",
    "letter",
    "archive",
    "backup",
];
pub(crate) const EXTS: &[&str] = &["pdf", "md", "txt", "rs", "png", "jpg", "docx", "swift", "key", "json"];
pub(crate) const SEPS: &[&str] = &[" ", "-", "_", ".", ""];

pub(crate) fn name(rng: &mut fastrand::Rng, ext: bool) -> String {
    let words = rng.usize(1..4);
    let mut s = String::new();
    for i in 0..words {
        if i > 0 {
            s.push_str(SEPS[rng.usize(..SEPS.len())]);
        }
        let w = WORDS[rng.usize(..WORDS.len())];
        if rng.u8(..4) == 0 {
            let mut c = w.chars();
            if let Some(f) = c.next() {
                s.extend(f.to_uppercase());
                s.push_str(c.as_str());
            }
        } else {
            s.push_str(w);
        }
    }
    if rng.u8(..5) == 0 {
        s.push_str(&rng.u16(..3000).to_string());
    }
    if rng.u8(..30) == 0 {
        s = format!("{s}-{}", "long".repeat(rng.usize(10..20)));
    }
    if ext {
        s.push('.');
        s.push_str(EXTS[rng.usize(..EXTS.len())]);
    }
    s
}

/// A random tree of about `n` entries below `/synthetic/root`. Returns it with its folder ids.
pub(crate) fn corpus(seed: u64, n: usize) -> (Snapshot, Vec<EntryId>) {
    let mut rng = fastrand::Rng::with_seed(seed);
    let mut b = Builder::with_capacity(n);
    let root = b.root(b"/synthetic/root", 1_700_000_000);
    let mut dirs = vec![root];
    while b.len() < n {
        let parent = dirs[rng.usize(..dirs.len())];
        let mtime = 1_700_000_000 - rng.u32(..300_000_000);
        let hidden = rng.u8(..25) == 0;
        let roll = rng.u8(..100);
        let mut nm = name(&mut rng, roll >= 15);
        if hidden {
            nm.insert(0, '.');
        }
        let mut f = if hidden { flags::HIDDEN } else { 0 };
        if roll < 15 {
            f |= flags::DIR;
            if rng.u8(..20) == 0 {
                nm.push_str(".app");
                f |= flags::PACKAGE;
            }
        } else if roll < 17 {
            f |= flags::SYMLINK;
        }
        let id = b.add(parent, nm.as_bytes(), f, mtime, rng.u64(..1 << 33));
        if f & (flags::DIR | flags::PACKAGE) == flags::DIR {
            dirs.push(id);
        }
    }
    (b.finish(), dirs)
}
