//! A deterministic synthetic list for the feature index's allocation test and benchmark, shaped
//! like an emoji grid: short made-up titles, several keywords per item, and keywords that many
//! items share, so a typed word often equals a keyword. Nothing is read from disk.

use slick_engine::{Item, key_of};

const SHAPES: &[&str] = &[
    "Face", "Heart", "Hand", "Star", "Moon", "Cat", "Dog", "Flag", "Ball", "Cup", "Leaf", "Bell", "Book", "Key",
    "Lamp", "Ring", "Shell", "Cloud", "Drop", "Wave",
];
const TRAITS: &[&str] = &[
    "Red",
    "Blue",
    "Green",
    "Pale",
    "Bright",
    "Small",
    "Large",
    "Smiling",
    "Winking",
    "Sleepy",
    "Grinning",
    "Crying",
    "Golden",
    "Silver",
    "Spotted",
    "Striped",
    "Folded",
    "Open",
    "Rolling",
    "Sparkling",
    "Crimson",
    "Twin",
    "Broken",
    "Tearful",
];
const EXTRAS: &[&str] = &[
    "with Sweat",
    "with Stars",
    "in Rain",
    "on Fire",
    "at Night",
    "with Bow",
    "",
    "",
    "",
];
/// Words features tag items with. Several are also title words, as with real emoji.
pub const TAGS: &[&str] = &[
    "love", "happy", "sad", "lol", "laugh", "smile", "joy", "cry", "heart", "cat", "dog", "night", "fire", "party",
    "nature", "weather", "animal", "food", "travel", "sport", "music", "money", "time", "sleep", "magic", "sparkle",
    "star", "moon", "win", "hug", "kiss", "cool", "wow", "ok", "yes", "no",
];

/// Item `i`: a title of a trait, a shape and sometimes an extra; one to five tags.
fn item(i: usize, mut next: impl FnMut() -> u64) -> Item {
    let r = next();
    let extra = EXTRAS[(r >> 16) as usize % EXTRAS.len()];
    let title = format!(
        "{} {}{}{}",
        TRAITS[(r % TRAITS.len() as u64) as usize],
        SHAPES[(r >> 8) as usize % SHAPES.len()],
        if extra.is_empty() { "" } else { " " },
        extra
    );
    let tags = 1 + (r >> 24) as usize % 5;
    let keywords = (0..tags)
        .map(|_| TAGS[next() as usize % TAGS.len()].to_string())
        .collect();
    Item {
        key: key_of(format!("tagged:{i}").as_bytes()),
        title,
        keywords,
        ..Item::default()
    }
}

/// `n` items, the same on every run.
pub fn catalog(n: usize) -> Vec<Item> {
    let mut x: u64 = 0x2545_F491_4F6C_DD1D;
    let mut next = move || {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        x.wrapping_mul(0x9E37_79B9_7F4A_7C15)
    };
    (0..n).map(|i| item(i, &mut next)).collect()
}

/// What people type into such a grid: tags, title words, and fragments of both.
pub const QUERIES: &[&str] = &[
    "heart",
    "love",
    "lol",
    "smile",
    "cat",
    "happy",
    "sad",
    "fire",
    "star",
    "moon",
    "party",
    "red heart",
    "grin",
    "sparkling star",
    "face with",
    "cry",
    "ok",
    "hug",
    "wink",
    "golden",
];
