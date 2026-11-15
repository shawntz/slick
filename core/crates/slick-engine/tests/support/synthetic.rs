//! A deterministic synthetic catalog for the allocation test and the benchmark: launcher-shaped
//! titles (apps, commands, settings, generated extension commands), some with aliases and
//! keywords, plus a heavy user's learning history. Nothing is read from disk.

use slick_engine::{Context, Engine, Item, Source, key_of, kind};

const APPS: &[&str] = &[
    "Safari",
    "Mail",
    "Calendar",
    "Notes",
    "Music",
    "Photos",
    "Messages",
    "Maps",
    "Terminal",
    "Preview",
    "System Settings",
    "Activity Monitor",
    "Disk Utility",
    "Font Book",
    "Keychain Access",
    "QuickTime Player",
    "TextEdit",
    "Calculator",
    "Reminders",
    "Shortcuts",
    "Screenshot",
    "Image Capture",
    "Photo Booth",
];
const VERBS: &[&str] = &[
    "Search", "Create", "Open", "Toggle", "Show", "Copy", "Manage", "List", "Start", "Stop", "Add", "Delete", "Export",
    "Import", "View", "Run", "Find", "Edit", "Share", "Sync",
];
const SERVICES: &[&str] = &[
    "Asana",
    "Trello",
    "GitHub",
    "Linear",
    "Notion",
    "Spotify",
    "Docker",
    "Figma",
    "Slack",
    "Zoom",
    "Dropbox",
    "Stripe",
    "Sentry",
    "Grafana",
    "Netlify",
    "Vercel",
    "Postman",
    "Discord",
    "Telegram",
    "YouTube Music",
    "Café Crème",
    "Pocket",
    "Readwise",
    "Obsidian",
    "Raindrop",
    "Bitwarden",
    "Kagi",
    "Ollama",
];
const NOUNS: &[&str] = &[
    "Issues",
    "Tasks",
    "Notes",
    "Pages",
    "Files",
    "Projects",
    "Bookmarks",
    "Tabs",
    "Repos",
    "Branches",
    "Commits",
    "Deployments",
    "Builds",
    "Logs",
    "Secrets",
    "Domains",
    "Invoices",
    "Customers",
    "Orders",
    "Events",
    "Meetings",
    "Playlists",
    "Albums",
    "Channels",
    "Messages",
    "Threads",
    "Teams",
    "Labels",
    "Folders",
    "Workspaces",
    "Boards",
    "Releases",
    "Packages",
    "Containers",
    "Images",
    "Dashboards",
    "Alerts",
    "Snippets",
];

/// Item `i` of the synthetic catalog.
fn item(i: usize) -> Item {
    let (title, kind) = if i < APPS.len() {
        (APPS[i].to_string(), kind::APP)
    } else {
        let v = VERBS[i % VERBS.len()];
        let s = SERVICES[(i / VERBS.len()) % SERVICES.len()];
        let n = NOUNS[(i / (VERBS.len() * SERVICES.len())) % NOUNS.len()];
        let title = match i % 3 {
            0 => format!("{v} {s} {n}"),
            1 => format!("{s}: {v} {n}"),
            _ => format!("{v} {n} in {s} {}", i % 97),
        };
        (
            title,
            if i.is_multiple_of(11) {
                kind::SETTING
            } else {
                kind::COMMAND
            },
        )
    };
    Item {
        key: key_of(format!("synthetic:{i}").as_bytes()),
        aliases: if i.is_multiple_of(50) {
            vec![format!("alias {}", i % 13)]
        } else {
            Vec::new()
        },
        keywords: if i.is_multiple_of(20) {
            vec![NOUNS[i % NOUNS.len()].to_lowercase()]
        } else {
            Vec::new()
        },
        title,
        kind,
        prior: 0.0,
        flags: 0,
    }
}

/// `n` items.
pub fn catalog(n: usize) -> Vec<Item> {
    (0..n).map(item).collect()
}

/// Unix time the synthetic history starts.
pub const T0: f64 = 1_780_000_000.0;

/// A heavy user: `events` executions over a year, spread over `distinct` items with a skewed
/// distribution, typed with prefixes of their titles, in varied contexts. Returns the time of the
/// last event.
pub fn train(e: &Engine, items: &[Item], events: usize, distinct: usize) -> f64 {
    let mut t = T0;
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut next = || {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    };
    for k in 0..events {
        t += 365.0 * 86_400.0 / events as f64;
        let r = next();
        // Roughly Zipf: small ranks far more often.
        let rank = ((r % 1_000) as f64 / 1_000.0).powi(3) * distinct as f64;
        let it = &items[(rank as usize * 7 + 3) % items.len()];
        let typed: String = it.title.chars().take(1 + (r >> 20) as usize % 6).collect();
        if k.is_multiple_of(25) {
            e.set_context(Context {
                now: t,
                hour: ((r >> 8) % 24) as u8,
                weekday: ((r >> 13) % 7) as u8,
                frontmost: items[(r >> 30) as usize % APPS.len()].key,
                display_count: 1 + ((r >> 40) % 2) as u8,
                audio_route: ((r >> 44) % 3) as u8,
                on_battery: (r >> 50) % 3 == 0,
                ..Context::default()
            })
            .expect("context");
        }
        let source = if k.is_multiple_of(4) {
            Source::Suggestion
        } else {
            Source::Typed
        };
        e.record(it.key, &typed, source, 0, t).expect("record");
    }
    t
}

/// Queries shaped like the matcher lab's: incremental prefixes, acronyms, mid-word fragments,
/// typos, multi-word and Unicode.
pub const QUERIES: &[&str] = &[
    "s",
    "sa",
    "saf",
    "safa",
    "t",
    "te",
    "ter",
    "term",
    "c",
    "cl",
    "cli",
    "clip",
    "w",
    "wi",
    "vsc",
    "ss",
    "gc",
    "tdm",
    "ch",
    "sp",
    "lh",
    "rh",
    "fari",
    "board",
    "ttings",
    "alend",
    "hrome",
    "ode",
    "sfari",
    "safaru",
    "termnial",
    "clipbaord",
    "dakr mode",
    "systme",
    "mode dark",
    "vs code",
    "wifi set",
    "half left",
    "search goo",
    "visual stu",
    "system set",
    "google chr",
    "creme brul",
    "café",
    "issue",
    "github iss",
    "notion pag",
    "create",
    "open",
    "toggle",
    "deploy",
    "sync rel",
    "a",
    "e",
    "o",
    "dash",
    "spot",
    "musi",
    "find",
    "zoom meet",
    "alias 3",
    "logs",
    "x",
    "q",
    "k",
    "z",
    "ma",
];
