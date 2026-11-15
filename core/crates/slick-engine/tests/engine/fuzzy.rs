//! Generic fuzzy indexes: the matcher without the learning.

use crate::fixtures::key;
use slick_engine::{FuzzyIndex, Item, Session};

fn item(title: &str, prior: f32) -> Item {
    Item {
        key: key(title),
        title: title.into(),
        prior,
        ..Item::default()
    }
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
    // lifts the word-prefix match "Pinned Party" over either.
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
