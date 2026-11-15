//! The catalog: every item root search can find, grouped by the source that provides it.

use slick_predict::hash::FxMap;
use std::collections::HashMap;

/// Item flags.
pub mod flags {
    /// Never shown in the zero-query suggestions (destructive or noisy commands).
    pub const NO_SUGGEST: u32 = 1;
    /// Executions are not learned (password generators and the like).
    pub const NO_LEARN: u32 = 2;
}

/// One searchable item as a source provides it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Item {
    /// FNV-1a hash of the item's id string (see `slick_predict::hash::fnv1a`).
    pub key: u64,
    /// Display title, matched first.
    pub title: String,
    /// Alternate names that count almost like the title.
    pub aliases: Vec<String>,
    /// Weaker search terms, ranked one tier below the same match on the title.
    pub keywords: Vec<String>,
    /// Item kind (see `rank::kind`), which sets a static prior.
    pub kind: u8,
    /// The item's own static prior in [0, 1], added to its kind prior.
    pub prior: f32,
    /// See [`flags`].
    pub flags: u32,
}

/// Items by source. A key belongs to one source at a time; adding it under another source moves it.
#[derive(Default)]
pub struct Catalog {
    sources: HashMap<u32, FxMap<u64, Item>>,
    owner: FxMap<u64, u32>,
}

impl Catalog {
    /// Replaces every item of `source` with `items`. A later duplicate key wins.
    pub fn replace_source(&mut self, source: u32, items: Vec<Item>) {
        if let Some(old) = self.sources.remove(&source) {
            for key in old.keys() {
                self.owner.remove(key);
            }
        }
        for item in items {
            self.upsert(source, item);
        }
        self.sources.entry(source).or_default();
    }

    /// Adds or replaces one item under `source`.
    pub fn upsert(&mut self, source: u32, item: Item) {
        if let Some(prev) = self.owner.insert(item.key, source)
            && prev != source
            && let Some(items) = self.sources.get_mut(&prev)
        {
            items.remove(&item.key);
        }
        self.sources.entry(source).or_default().insert(item.key, item);
    }

    /// Removes the item with `key`. Returns false when there was none.
    pub fn remove(&mut self, key: u64) -> bool {
        let Some(source) = self.owner.remove(&key) else {
            return false;
        };
        self.sources
            .get_mut(&source)
            .is_some_and(|items| items.remove(&key).is_some())
    }

    /// Every item, in no particular order.
    pub fn items(&self) -> impl Iterator<Item = &Item> {
        self.sources.values().flat_map(|items| items.values())
    }

    /// Number of items.
    pub fn len(&self) -> usize {
        self.owner.len()
    }

    /// True when the catalog holds no items.
    pub fn is_empty(&self) -> bool {
        self.owner.is_empty()
    }

    /// Number of sources that were ever given items.
    pub fn sources(&self) -> usize {
        self.sources.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(key: u64, title: &str) -> Item {
        Item {
            key,
            title: title.into(),
            ..Item::default()
        }
    }

    #[test]
    fn sources_replace_upsert_and_remove() {
        let mut c = Catalog::default();
        c.replace_source(1, vec![item(1, "A"), item(2, "B"), item(2, "B2")]);
        assert_eq!(c.len(), 2);
        c.upsert(2, item(2, "moved"));
        c.replace_source(1, vec![item(3, "C")]);
        let mut titles: Vec<&str> = c.items().map(|i| i.title.as_str()).collect();
        titles.sort_unstable();
        assert_eq!(titles, vec!["C", "moved"]);
        assert!(c.remove(2));
        assert!(!c.remove(2));
        assert_eq!(c.len(), 1);
    }
}
