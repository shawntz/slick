//! Deterministic synthetic corpora for the matcher tests.
//!
//! The tests compare fast paths against reference paths over thousands of items, so they need
//! realistic shapes: multi-word titles, acronyms, punctuation, long titles past the 64-byte bitmap
//! window, and file paths with code-style names, dates and camera file names. Every string is made
//! from the word lists below. Nothing is read from disk.

/// Small xorshift64* generator, so the corpus is identical on every run and every machine.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.below(items.len())]
    }
}

const WORDS: &[&str] = &[
    "alpha", "anchor", "atlas", "audio", "beacon", "board", "bridge", "canvas", "capture", "chart", "clip", "cloud",
    "code", "color", "control", "dark", "deck", "desk", "dock", "draft", "echo", "editor", "field", "file", "focus",
    "frame", "glass", "grid", "harbor", "history", "image", "index", "journal", "kernel", "lens", "library", "light",
    "list", "mail", "manager", "map", "matrix", "meeting", "memo", "menu", "mode", "monitor", "music", "note", "orbit",
    "panel", "photo", "pilot", "pixel", "planner", "preview", "quick", "radar", "reader", "record", "script", "search",
    "settings", "share", "signal", "snippet", "sound", "studio", "switch", "system", "tab", "task", "terminal",
    "timer", "toggle", "tool", "track", "vault", "video", "view", "window", "word", "work", "zone",
];
const VERBS: &[&str] = &[
    "Open", "Search", "Toggle", "Show", "Create", "Copy", "Clear", "Start", "Stop", "Switch", "Run", "Find",
];
const BRANDED: &[&str] = &[
    "GitHub", "iCloud", "macOS", "YouTube", "FaceTime", "AirDrop", "PDFKit", "WebView",
];
const CODE_EXT: &[&str] = &[
    "rs", "swift", "ts", "py", "go", "c", "h", "md", "json", "toml", "yaml", "sh",
];
const DOC_EXT: &[&str] = &["pdf", "pdf", "docx", "xlsx", "key", "txt", "md", "csv", "png", "jpg"];
const DIRS: &[&str] = &[
    "src", "tests", "docs", "scripts", "assets", "lib", "Sources", "Tests", "notes", "archive",
];

fn capitalized(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

fn title_words(rng: &mut Rng, count: usize) -> String {
    (0..count)
        .map(|_| capitalized(rng.pick(WORDS)))
        .collect::<Vec<_>>()
        .join(" ")
}

/// `n` launcher-style titles: app names, commands, branded names, settings panes and a few long
/// titles that do not fit the 64-byte bitmap window.
pub fn titles(n: usize, seed: u64) -> Vec<String> {
    let mut rng = Rng(seed | 1);
    (0..n)
        .map(|i| {
            let kind = rng.below(10);
            let words = 1 + rng.below(3);
            match kind {
                0..=2 => title_words(&mut rng, words),
                3..=5 => {
                    let verb = rng.pick(VERBS);
                    format!("{verb} {}", title_words(&mut rng, words))
                }
                6 => {
                    let brand = rng.pick(BRANDED);
                    format!("{brand} {}", title_words(&mut rng, words.min(2)))
                }
                7 => {
                    let head = title_words(&mut rng, 1);
                    format!("{head}: {}", title_words(&mut rng, 2))
                }
                8 => format!("{}-{} {}", rng.pick(WORDS), rng.pick(WORDS), 2000 + i % 30),
                _ => title_words(&mut rng, 7 + words * 2),
            }
        })
        .collect()
}

fn code_name(rng: &mut Rng) -> String {
    let count = 1 + rng.below(3);
    let parts: Vec<&str> = (0..count).map(|_| rng.pick(WORDS)).collect();
    match rng.below(4) {
        0 => parts.join("_"),
        1 => parts.join("-"),
        2 => parts[0].to_string() + &parts[1..].iter().map(|p| capitalized(p)).collect::<String>(),
        _ => parts.iter().map(|p| capitalized(p)).collect(),
    }
}

/// `n` file paths under `/synthetic`: project trees with code files, document folders, dated
/// screenshots and camera images.
pub fn paths(n: usize, seed: u64) -> Vec<String> {
    let mut rng = Rng(seed | 1);
    (0..n)
        .map(|_| {
            let project = code_name(&mut rng);
            let dir = rng.pick(DIRS);
            let file = match rng.below(8) {
                0 => "main.rs".to_string(),
                1 => "lib.rs".to_string(),
                2 => "README.md".to_string(),
                3 => format!("IMG_{:04}.HEIC", rng.below(10_000)),
                4 => format!(
                    "Screenshot 20{:02}-{:02}-{:02} at {}.{:02}.png",
                    15 + rng.below(12),
                    1 + rng.below(12),
                    1 + rng.below(28),
                    rng.below(24),
                    rng.below(60)
                ),
                5 => {
                    let words = 1 + rng.below(3);
                    format!("{}.{}", title_words(&mut rng, words), rng.pick(DOC_EXT))
                }
                _ => format!("{}.{}", code_name(&mut rng), rng.pick(CODE_EXT)),
            };
            format!("/synthetic/{project}/{dir}/{file}")
        })
        .collect()
}
