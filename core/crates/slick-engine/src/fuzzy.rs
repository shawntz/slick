//! Generic fuzzy indexes for features (clipboard history, snippets, emoji and the like). They
//! share the matcher and the ranking layout with root search and none of the learning.

use crate::catalog::Item;
use crate::engine::EngineError;
use crate::index::Index;
use crate::rank::RankParams;
use crate::session::{Hit, Session, TextRules};
use std::sync::{Arc, RwLock};

/// How feature lists rank text. A later whole word stays below literal prefixes, which only root
/// search promotes. A keyword equal to the whole query ranks in the exact tier, so "love" lists
/// what a feature tagged love above a title that only starts with it. Inside a tier a title match
/// still ranks first: its field bonus, 2,000, is larger than any prior's lift, 1,000.
const FEATURE_LISTS: TextRules = TextRules {
    whole_words: false,
    exact_keywords: true,
};

/// A searchable list of items owned by one feature.
///
/// Safe to use from any thread: `set_items` builds the new index outside the lock and swaps it in;
/// queries take a read lock.
pub struct FuzzyIndex {
    index: RwLock<Arc<Index>>,
}

impl Default for FuzzyIndex {
    fn default() -> Self {
        FuzzyIndex {
            index: RwLock::new(Arc::new(Index::build([], |_| 0))),
        }
    }
}

impl FuzzyIndex {
    /// An empty index.
    pub fn new() -> FuzzyIndex {
        FuzzyIndex::default()
    }

    /// Replaces every item. An item's `prior` lifts it inside its tier; `kind` and `flags` are
    /// ignored.
    pub fn set_items(&self, items: &[Item]) -> Result<(), EngineError> {
        let p = RankParams::default();
        let index = Arc::new(Index::build(items, |i| p.static_lift(0, i.prior)));
        *self.index.write().map_err(|_| EngineError::Poisoned)? = index;
        Ok(())
    }

    /// Number of items.
    pub fn len(&self) -> Result<usize, EngineError> {
        Ok(self.current()?.len())
    }

    /// True when the index holds no items.
    pub fn is_empty(&self) -> Result<bool, EngineError> {
        Ok(self.len()? == 0)
    }

    fn current(&self) -> Result<Arc<Index>, EngineError> {
        Ok(Arc::clone(&*self.index.read().map_err(|_| EngineError::Poisoned)?))
    }

    /// The best `k` items for `text`.
    pub fn query<'s>(&self, session: &'s mut Session, text: &str, k: usize) -> Result<&'s [Hit], EngineError> {
        let ix = self.current()?;
        session.begin(&ix, text, FEATURE_LISTS);
        session.run(&ix, k, Some(&ix.static_lift), &ix.static_seeds);
        Ok(&session.hits)
    }

    /// Highlight ranges of `key`'s title for the session's last query, as UTF-16 (start, length).
    pub fn ranges<'s>(&self, session: &'s mut Session, key: u64) -> Result<&'s [(u32, u32)], EngineError> {
        let ix = self.current()?;
        session.ranges.clear();
        match ix.position(key) {
            Some(pos) if session.target == ix.generation => Ok(session.title_ranges(&ix, pos)),
            _ => Ok(&session.ranges),
        }
    }
}
