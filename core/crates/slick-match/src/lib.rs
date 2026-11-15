//! slick-match: launcher-grade fuzzy matching over a flat structure-of-arrays arena.
//!
//! - [`Arena`] holds every item's match strings (a title, aliases, keywords) folded to lowercase
//!   with diacritics stripped, one char to one char, in one contiguous buffer, plus per-entry
//!   presence masks, word-initial masks and word-start bitmaps. Titles and file paths share it; for
//!   paths the basename is scored first.
//! - [`Query`] is folded the same way and reused across keystrokes.
//! - [`search`] runs the mask prefilter, the NEON bitmaps, tier classification and a bounded
//!   top k; [`Session`] adds incremental narrowing; `search_par` (feature `parallel`) splits large
//!   arenas over rayon.
//! - [`rank`] is the rank layout every ranked list shares: tiers never mix, title beats alias beats
//!   keyword, and callers add within-tier lifts.
//! - [`highlight::ranges`] computes UTF-16 highlight ranges for the visible rows only.

pub mod arena;
pub mod bits;
pub mod fold;
pub mod highlight;
pub mod query;
pub mod rank;
pub mod score;
pub mod search;

pub use arena::{Arena, PAD};
pub use highlight::HighlightScratch;
pub use query::Query;
pub use rank::{Field, MAX_LIFT, TIER_GAP};
pub use score::{Needle, TIER_NAMES, TextScore, Unit};
#[cfg(feature = "parallel")]
pub use search::search_par;
pub use search::{Hit, Opts, Scratch, Session, search, search_seeded};

#[cfg(test)]
mod tests;
