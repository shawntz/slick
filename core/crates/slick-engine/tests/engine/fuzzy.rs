//! Generic fuzzy indexes: the matcher without the learning.

use crate::fixtures::{T0, context, key};
use slick_engine::{Engine, EngineParams, FuzzyIndex, Item, Session};

fn item(title: &str, prior: f32) -> Item {
    Item {
        key: key(title),
        title: title.into(),
        prior,
        ..Item::default()
    }
}

/// An item a feature tagged with `keywords`. `prior` stands for the feature's rank hint.
fn tagged(title: &str, keywords: &[&str], prior: f32) -> Item {
    Item {
        keywords: keywords.iter().map(|k| k.to_string()).collect(),
        ..item(title, prior)
    }
}

/// An index with the items it was built from, to name its hits.
struct Listed {
    index: FuzzyIndex,
    items: Vec<Item>,
}

impl Listed {
    fn new(items: &[Item]) -> Listed {
        let index = FuzzyIndex::new();
        index.set_items(items).expect("items");
        Listed {
            index,
            items: items.to_vec(),
        }
    }

    /// Titles, tiers and fields of the hits for `text`, best first.
    fn ranked(&self, text: &str) -> Vec<(String, u8, u8)> {
        let mut s = Session::new();
        let hits = self.index.query(&mut s, text, 50).expect("query").to_vec();
        hits.iter()
            .map(|h| {
                let title = self.items.iter().find(|i| i.key == h.key).map(|i| i.title.clone());
                (title.unwrap_or_default(), h.tier, h.field)
            })
            .collect()
    }
}

const EXACT: u8 = 6;
const PREFIX: u8 = 5;
const WORD_PREFIX: u8 = 4;
const TITLE: u8 = 0;
const KEYWORD: u8 = 2;

fn titles(hits: &[(String, u8, u8)]) -> Vec<&str> {
    hits.iter().map(|h| h.0.as_str()).collect()
}

#[test]
fn set_query_ranges_and_replace() {
    let index = FuzzyIndex::new();
    let mut s = Session::new();
    assert!(index.query(&mut s, "x", 10).expect("query").is_empty());
    index
        .set_items(&[
            item("Grinning Face 😀", 0.0),
            item("Party Popper 🎉", 0.0),
            item("Party Streamers Pack", 1.0),
            item("Pinned Party", 1.0),
        ])
        .expect("items");
    assert_eq!(index.len().expect("len"), 4);
    let hits = index.query(&mut s, "party", 10).expect("query").to_vec();
    assert_eq!(hits.len(), 3);
    // The prior lifts the longer title over the shorter one inside the prefix tier, but never
    // lifts the word-prefix match "Pinned Party" over either. Unlike root search, a feature index
    // does not rank a whole later word with literal prefixes.
    let order: Vec<u64> = hits.iter().map(|h| h.key).collect();
    assert_eq!(
        order,
        vec![key("Party Streamers Pack"), key("Party Popper 🎉"), key("Pinned Party")]
    );
    assert_eq!(index.ranges(&mut s, key("Party Popper 🎉")).expect("ranges"), &[(0, 5)]);
    index.set_items(&[item("Confetti", 0.0)]).expect("items");
    assert_eq!(index.query(&mut s, "conf", 10).expect("query")[0].key, key("Confetti"));
    assert!(index.ranges(&mut s, key("Party Popper 🎉")).expect("ranges").is_empty());
}

/// "heart", "love" and "lol" in an emoji-like grid: a keyword equal to the query puts the item in
/// the exact tier, above titles that only start with the query, and those keyword matches follow
/// the feature's prior. All items are made up.
#[test]
fn a_keyword_equal_to_the_query_ranks_in_the_exact_tier() {
    let index = Listed::new(&[
        tagged("Crimson Heart", &["heart", "love"], 1.0),
        item("Heart Lantern", 0.0),
        item("Heartwood Leaf", 0.5),
        tagged("Pale Heart", &["heart"], 0.2),
        item("Love Pavilion", 0.0),
        item("Lovebird Feather", 0.0),
        tagged("Twin Hearts", &["love"], 0.6),
        tagged("Kiss Stamp", &["love", "kiss"], 0.3),
        item("Lolly Swirl", 0.0),
        tagged("Tearful Grin", &["lol", "laugh"], 0.9),
        tagged("Rolling Grin", &["lol", "rofl"], 0.4),
    ]);
    let heart = index.ranked("heart");
    assert_eq!(&titles(&heart)[..2], ["Crimson Heart", "Pale Heart"]);
    assert!(heart[..2].iter().all(|h| (h.1, h.2) == (EXACT, KEYWORD)));
    assert!(heart[2..4].iter().all(|h| (h.1, h.2) == (PREFIX, TITLE)), "{heart:?}");
    let love = index.ranked("love");
    assert_eq!(
        &titles(&love)[..3],
        ["Crimson Heart", "Twin Hearts", "Kiss Stamp"],
        "by prior"
    );
    assert!(love[..3].iter().all(|h| h.1 == EXACT));
    assert_eq!(
        love[3..].iter().map(|h| (h.1, h.2)).collect::<Vec<_>>(),
        [(PREFIX, TITLE), (PREFIX, TITLE)]
    );
    let lol = index.ranked("lol");
    assert_eq!(&titles(&lol)[..3], ["Tearful Grin", "Rolling Grin", "Lolly Swirl"]);
    assert_eq!(lol[2].1, PREFIX);
}

/// The cases around it: an exact title still leads an exact keyword with a higher prior, a keyword
/// that only starts with the query stays a tier down, the keyword folds as a title does, equal
/// priors fall to the shorter title, and root search keeps an exact keyword one tier down.
#[test]
fn an_exact_keyword_stays_below_an_exact_title_and_only_whole_keywords_move() {
    let items = [
        item("Spark", 0.0),
        tagged("Flash Card", &["spark"], 1.0),
        tagged("Bright Idea Lamp", &["spark"], 0.0),
        tagged("Idea", &["spark"], 0.0),
        tagged("Sparkler", &["sparkles"], 1.0),
        tagged("Glitter", &["sparkly"], 0.0),
        item("Sparks Fly", 0.0),
        tagged("Coffee Cup", &["Café Crème"], 0.0),
    ];
    let index = Listed::new(&items);
    let spark = index.ranked("spark");
    assert_eq!(
        &titles(&spark)[..4],
        ["Spark", "Flash Card", "Idea", "Bright Idea Lamp"],
        "an exact title first, then by prior, then the shorter title"
    );
    assert_eq!(spark[0].2, TITLE);
    assert!(spark[..4].iter().all(|h| h.1 == EXACT));
    assert_eq!(
        &titles(&spark)[4..6],
        ["Sparkler", "Sparks Fly"],
        "title prefixes, by prior"
    );
    assert!(spark[4..6].iter().all(|h| (h.1, h.2) == (PREFIX, TITLE)));
    assert_eq!(
        spark[6],
        ("Glitter".to_string(), WORD_PREFIX, KEYWORD),
        "a keyword prefix"
    );
    for text in ["CAFE CREME", "café  crème", " Cafe Creme "] {
        assert_eq!(
            index.ranked(text).first(),
            Some(&("Coffee Cup".to_string(), EXACT, KEYWORD))
        );
    }
    // Root search ranks the same items with an exact keyword one tier down.
    let e = Engine::in_memory(EngineParams::default());
    e.replace_source(1, items.to_vec()).expect("catalog");
    e.set_context(context(T0, 0)).expect("context");
    let mut s = Session::new();
    let root: Vec<(u64, u8)> = e
        .query(&mut s, "spark", 10)
        .expect("query")
        .iter()
        .map(|h| (h.key, h.tier))
        .collect();
    let at = |title: &str| root.iter().position(|h| h.0 == key(title)).unwrap_or(usize::MAX);
    assert_eq!(root[0], (key("Spark"), EXACT));
    assert_eq!(root[at("Flash Card")].1, PREFIX);
    assert!(
        at("Sparks Fly") < at("Flash Card") && at("Sparkler") < at("Flash Card"),
        "title prefixes before a keyword in root search"
    );
}
