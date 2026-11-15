//! The two launcher expectation suites, run against the synthetic launcher corpus:
//!
//! - the matcher lab's 33 expectations, which the matcher was tuned on;
//! - the critic's 45 held-out expectations, written before the matcher ever ran on them;
//! - 20 expectations written by the core's verifier before running them.
//!
//! Each suite runs on text alone and with an app kind prior (a within-tier lift for apps, as the
//! engine applies it). Some expectations cannot pass on text alone under the ranking contract:
//! they need learning, which may lift an item by one tier. Those are listed with the reason, and
//! the test fails when the set of misses changes in either direction, so an improvement or a
//! regression is never silent.

use crate::launcher_corpus::{self, LauncherCorpus};
use slick_match::{Arena, Opts, Query, Scratch, search};

struct Exp {
    q: &'static str,
    want: &'static str,
    top: usize,
}

const fn exp(q: &'static str, want: &'static str, top: usize) -> Exp {
    Exp { q, want, top }
}

/// A want that starts with '!' must not appear in the top `top`.
const LAB: &[Exp] = &[
    exp("saf", "Safari", 1),
    exp("vsc", "Visual Studio Code", 1),
    exp("vs code", "Visual Studio Code", 1),
    exp("code", "Visual Studio Code", 3),
    exp("ss", "System Settings", 3),
    exp("gc", "Google Chrome", 3),
    exp("sfari", "Safari", 1),
    exp("safaru", "Safari", 1),
    exp("termnial", "Terminal", 1),
    exp("term", "Terminal", 1),
    exp("term", "!Thermal Monitor", 5),
    exp("termin", "Terminal", 1),
    exp("calc", "Calculator", 1),
    exp("dark", "Toggle Dark Mode", 3),
    exp("tdm", "Toggle Dark Mode", 1),
    exp("mode dark", "Toggle Dark Mode", 1),
    exp("sys set", "System Settings", 1),
    exp("cafe", "Café", 1),
    exp("café", "Café", 1),
    exp("creme brulee", "Crème Brûlée Recipe", 1),
    exp("微信", "微信", 1),
    exp("云音", "网易云音乐", 1),
    exp("カレ", "カレンダー", 1),
    exp("🎉", "🎉 Confetti", 1),
    exp("confetti", "🎉 Confetti", 2),
    exp("calendar", "Calendar", 1),
    exp("safari", "Safari", 1),
    exp("wifi", "Wi-Fi Settings", 1),
    exp("fari", "Safari", 1),
    exp("ghpr", "GitHub: My Pull Requests", 1),
    exp("clipboard", "Clipboard History", 1),
    exp("lh", "Left Half", 1),
    exp("chrome", "Google Chrome", 3),
];

const HELD_OUT: &[Exp] = &[
    exp("msg", "Messages", 3),
    exp("activity", "Activity Monitor", 1),
    exp("actmon", "Activity Monitor", 1),
    exp("am", "Activity Monitor", 5),
    exp("rh", "Right Half", 2),
    exp("max", "Maximize", 1),
    exp("cent", "Center", 1),
    exp("empty", "Empty Trash", 1),
    exp("et", "Empty Trash", 3),
    exp("dnd", "Toggle Do Not Disturb", 3),
    exp("screenshot", "Screenshot", 1),
    exp("take scr", "Take Screenshot", 1),
    exp("blue", "Bluetooth Settings", 3),
    exp("disk ut", "Disk Utility", 1),
    exp("du", "Disk Utility", 3),
    exp("ka", "Keychain Access", 3),
    exp("qt", "QuickTime Player", 3),
    exp("quick time", "QuickTime Player", 1),
    exp("prev", "Preview", 1),
    exp("notes", "Notes", 1),
    exp("musc", "Music", 1),
    exp("calender", "Calendar", 1),
    exp("systme settings", "System Settings", 1),
    exp("fotos", "Photos", 3),
    exp("settings wifi", "Wi-Fi Settings", 1),
    exp("dark mode", "Toggle Dark Mode", 1),
    exp("uuid", "Generate UUID", 1),
    exp("json", "Format JSON", 2),
    exp("kill", "Kill Process", 1),
    exp("ip", "Show IP Address", 5),
    exp("gh", "Search GitHub", 3),
    exp("yt", "Search YouTube", 3),
    exp("vol up", "Volume Up", 1),
    exp("lock", "Lock Screen", 1),
    exp("restart", "Restart", 1),
    exp("conv cur", "Convert Currency", 1),
    exp("tz", "Convert Time Zones", 3),
    exp("fb", "Font Book", 3),
    exp("ic", "Image Capture", 3),
    exp("mc", "Mission Control", 3),
    exp("remind", "Reminders", 1),
    exp("txt", "TextEdit", 3),
    exp("sysinfo", "System Information", 1),
    exp("pb", "Photo Booth", 3),
    exp("short", "Shortcuts", 1),
];

/// Ordinary launcher queries, written before the matcher ever ran on them (a second held-out set).
const VERIFIER: &[Exp] = &[
    exp("mail", "Mail", 1),
    exp("fin", "Finder", 3),
    exp("sys info", "System Information", 1),
    exp("xc", "Xcode", 3),
    exp("facetime", "FaceTime", 1),
    exp("ft", "FaceTime", 5),
    exp("kc", "Keychain Access", 5),
    exp("remin", "Reminders", 1),
    exp("weathr", "Weather", 1),
    exp("pohtos", "Photos", 1),
    exp("night shift", "Night Shift Settings", 2),
    exp("empty tr", "Empty Trash", 1),
    exp("ql", "Quick Look", 3),
    exp("screen rec", "Screen Recording Settings", 2),
    exp("uuid gen", "Generate UUID", 1),
    exp("base64 dec", "Base64 Decode", 1),
    exp("clip hist", "Clipboard History", 1),
    exp("act mon", "Activity Monitor", 1),
    exp("vol down", "Volume Down", 1),
    exp("tmach", "Time Machine", 2),
];

/// Within-tier lift for apps in the "with app prior" runs: the engine's app kind prior.
const APP_LIFT: i32 = 600;

const CODE: (&str, &str) = (
    "code -> Visual Studio Code",
    "Codex, Code Snippets and Code Review Checklist are literal prefixes; only learning may lift a word-prefix match one tier",
);
const CHROME: (&str, &str) = (
    "chrome -> Google Chrome",
    "four Chrome: commands are literal prefixes; only learning may lift a word-prefix match one tier",
);
const GH: (&str, &str) = (
    "gh -> Search GitHub",
    "a generated contact (Grace Haddad, a prefix-tier acronym) and the GitHub: commands (no skipped first word) rank above it on text",
);
const FOTOS: (&str, &str) = ("fotos -> Photos", "two edits (f for ph); the typo tier allows one");
const KC: (&str, &str) = (
    "kc -> Keychain Access",
    "Keychain is one word, so c is mid-word; contacts and commands with K and C word initials are word-prefix covers",
);

/// Misses on text alone, with why each is not a matcher defect.
const KNOWN_TEXT_MISSES: &[(&str, &str)] = &[
    CODE,
    CHROME,
    GH,
    FOTOS,
    (
        "ss -> System Settings",
        "SSH Settings, Screen Sharing and other two-word covers tie with it on text; the app prior decides",
    ),
    (
        "ka -> Keychain Access",
        "generated contacts such as Karen Allen are equally strong acronym covers; the app prior decides",
    ),
    KC,
];
/// Misses with the app kind prior.
const KNOWN_PRIOR_MISSES: &[(&str, &str)] = &[CODE, CHROME, GH, FOTOS, KC];

struct Run<'a> {
    corpus: &'a LauncherCorpus,
    arena: Arena,
    lift: Option<Vec<i32>>,
}

impl Run<'_> {
    fn rank(&self, q: &str, want: &str) -> Option<usize> {
        let mut scratch = Scratch::default();
        let mut hits = Vec::new();
        search(
            &self.arena,
            &Query::new(q),
            &Opts::default(),
            None,
            self.lift.as_deref(),
            &mut scratch,
            &mut hits,
        );
        hits.iter()
            .position(|h| self.corpus.titles[h.idx as usize] == want)
            .map(|p| p + 1)
    }

    /// Runs a suite and returns the labels of the misses, printing each row.
    fn misses(&self, suite: &[Exp], label: &str) -> Vec<String> {
        let mut out = Vec::new();
        for e in suite {
            let (negative, want) = match e.want.strip_prefix('!') {
                Some(w) => (true, w),
                None => (false, e.want),
            };
            let rank = self.rank(e.q, want);
            let pass = if negative {
                rank.is_none_or(|r| r > e.top)
            } else {
                rank.is_some_and(|r| r <= e.top)
            };
            println!(
                "{label:>8} {:<20} {:<28} top {} -> {:?} {}",
                e.q,
                e.want,
                e.top,
                rank,
                if pass { "" } else { "MISS" }
            );
            if !pass {
                out.push(format!("{} -> {}", e.q, e.want));
            }
        }
        out
    }
}

fn check(suite: &[Exp], name: &str) {
    let corpus = launcher_corpus::build();
    let arena = Arena::from_titles(corpus.titles.iter().map(String::as_str));
    let lift: Vec<i32> = corpus.is_app.iter().map(|&a| if a { APP_LIFT } else { 0 }).collect();
    let text = Run {
        corpus: &corpus,
        arena,
        lift: None,
    };
    let text_misses = text.misses(suite, "text");
    let prior = Run {
        lift: Some(lift),
        ..text
    };
    let prior_misses = prior.misses(suite, "prior");
    let known = |list: &[(&str, &str)]| -> Vec<String> {
        let mut v: Vec<String> = list
            .iter()
            .map(|(k, _)| k.to_string())
            .filter(|k| suite.iter().any(|e| format!("{} -> {}", e.q, e.want) == *k))
            .collect();
        v.sort();
        v
    };
    let mut text_misses = text_misses;
    let mut prior_misses = prior_misses;
    text_misses.sort();
    prior_misses.sort();
    println!(
        "{name}: text {}/{} pass, with app prior {}/{} pass",
        suite.len() - text_misses.len(),
        suite.len(),
        suite.len() - prior_misses.len(),
        suite.len()
    );
    assert_eq!(text_misses, known(KNOWN_TEXT_MISSES), "{name}: text misses changed");
    assert_eq!(
        prior_misses,
        known(KNOWN_PRIOR_MISSES),
        "{name}: misses with the app prior changed"
    );
}

#[test]
fn lab_expectations() {
    check(LAB, "lab");
}

#[test]
fn held_out_expectations() {
    check(HELD_OUT, "held-out");
}

#[test]
fn verifier_expectations() {
    check(VERIFIER, "verifier");
}
