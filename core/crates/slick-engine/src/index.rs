//! The immutable search index built from a catalog or a feature's item list.
//!
//! Items are ordered by title length in chars, then by key, so the matcher's tie-break on lower
//! position is the contract's tie-break: shorter title, then smaller key.

use crate::catalog::Item;
use slick_match::Arena;
use slick_predict::hash::FxMap;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

/// How many items a query visits first, as seeds for the running top-k threshold. Enough that the
/// seeds matching a typical short query fill a top 50.
pub const SEEDS: usize = 256;

/// The positions of the `SEEDS` largest values of `lift` among `candidates`, largest first, ties
/// to the lower position. `scratch` is reused; `out` is replaced.
pub(crate) fn top_positions(
    lift: &[i32],
    candidates: impl Iterator<Item = u32>,
    scratch: &mut Vec<(i32, u32)>,
    out: &mut Vec<u32>,
) {
    scratch.clear();
    scratch.extend(candidates.filter_map(|p| lift.get(p as usize).map(|&l| (l, p))));
    let order = |a: &(i32, u32), b: &(i32, u32)| b.0.cmp(&a.0).then(a.1.cmp(&b.1));
    if scratch.len() > SEEDS {
        scratch.select_nth_unstable_by(SEEDS - 1, order);
        scratch.truncate(SEEDS);
    }
    scratch.sort_unstable_by(order);
    scratch.dedup_by_key(|x| x.1);
    out.clear();
    out.extend(scratch.iter().map(|x| x.1));
}

/// A search index over a fixed set of items.
pub struct Index {
    /// Unique across every index of the process; sessions use it to notice a new index.
    pub generation: u64,
    /// The matcher's arena, one item per position.
    pub arena: Arena,
    /// Item key per position.
    pub keys: Vec<u64>,
    /// Item kind per position.
    pub kinds: Vec<u8>,
    /// Item flags per position.
    pub flags: Vec<u32>,
    /// Within-tier lift from the kind and item priors, per position.
    pub static_lift: Vec<i32>,
    /// The positions with the largest static lift, at most [`SEEDS`], largest first. A query
    /// visits them first; see `slick_match::search_seeded`.
    pub static_seeds: Vec<u32>,
    text: String,
    text_start: Vec<u32>,
    positions: FxMap<u64, u32>,
}

impl Index {
    /// Builds an index of `items`, with `lift` giving each item's static lift. When two items
    /// share a key, the later one wins.
    pub fn build<'a>(items: impl IntoIterator<Item = &'a Item>, lift: impl Fn(&Item) -> i32) -> Index {
        let mut unique: FxMap<u64, &Item> = FxMap::default();
        for item in items {
            unique.insert(item.key, item);
        }
        let mut items: Vec<&Item> = unique.into_values().collect();
        items.sort_by_cached_key(|i| (i.title.chars().count(), i.key));
        let mut ix = Index {
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            arena: Arena::new(false),
            keys: Vec::with_capacity(items.len()),
            kinds: Vec::with_capacity(items.len()),
            flags: Vec::with_capacity(items.len()),
            static_lift: Vec::with_capacity(items.len()),
            static_seeds: Vec::new(),
            text: String::new(),
            text_start: vec![0],
            positions: FxMap::default(),
        };
        let kept = |s: &&String| !s.trim().is_empty();
        for (pos, item) in items.iter().enumerate() {
            ix.arena.push_item(
                &item.title,
                item.aliases.iter().filter(kept).map(String::as_str),
                item.keywords.iter().filter(kept).map(String::as_str),
            );
            for s in std::iter::once(&item.title)
                .chain(item.aliases.iter().filter(kept))
                .chain(item.keywords.iter().filter(kept))
            {
                ix.text.push_str(s);
                ix.text_start.push(ix.text.len() as u32);
            }
            ix.keys.push(item.key);
            ix.kinds.push(item.kind);
            ix.flags.push(item.flags);
            ix.static_lift.push(lift(item));
            ix.positions.insert(item.key, pos as u32);
        }
        ix.arena.shrink();
        let mut scratch = Vec::new();
        let mut seeds = Vec::new();
        top_positions(&ix.static_lift, 0..ix.keys.len() as u32, &mut scratch, &mut seeds);
        ix.static_seeds = seeds;
        ix
    }

    /// Number of items.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// True when the index holds no items.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The position of the item with `key`.
    pub fn position(&self, key: u64) -> Option<u32> {
        self.positions.get(&key).copied()
    }

    /// The original text of arena entry `e`.
    pub fn entry_text(&self, e: usize) -> &str {
        let (a, b) = (self.text_start[e] as usize, self.text_start[e + 1] as usize);
        &self.text[a..b]
    }

    /// The title of the item at `pos`.
    pub fn title(&self, pos: u32) -> &str {
        self.entry_text(self.arena.entry_range(pos as usize).start)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positions_follow_title_length_then_key() {
        let items = [(9, "Mail"), (3, "Maps"), (1, "Messages"), (2, "Mai")];
        let items: Vec<Item> = items
            .iter()
            .map(|&(key, t)| Item {
                key,
                title: t.into(),
                aliases: vec!["".into(), "alt".into()],
                ..Item::default()
            })
            .collect();
        let ix = Index::build(&items, |_| 0);
        assert_eq!(ix.keys, vec![2, 3, 9, 1]);
        assert_eq!(ix.title(ix.position(9).unwrap_or(0)), "Mail");
        assert_eq!(ix.entry_text(1), "alt");
        assert_eq!(ix.arena.entries(), 8);
    }
}
