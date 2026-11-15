//! Slick's own file index: a tree walker, a memory-mapped store and path-aware search.
//!
//! Spotlight took 130 to 1,600 ms for a first batch of name matches, so the launcher keeps its own
//! index of file names. Content search stays with Spotlight.
//!
//! - [`FileIndex`] owns the published [`Snapshot`] and the writer. Readers take a snapshot, which
//!   costs one `Arc` clone under a read lock, and never wait for a rescan.
//! - [`walk`] enumerates roots with `getattrlistbulk` on several threads, with caller-given
//!   [`Rules`].
//! - [`FileIndex::apply`] takes FSEvents paths and flags and rescans only what changed.
//! - [`Searcher`] runs name, folder, extension and path-fragment queries with `slick_match` tiers,
//!   a bounded top k and narrowing, on threads the caller owns ([`ParallelFor`]).
//! - [`FileIndex::save`] and [`FileIndex::open`] persist one memory-mapped file with a versioned
//!   header and a checksum.
//!
//! The crate's README has the API walkthrough and the measured numbers. The C ABI for it lives in
//! `slick-ffi/src/files.rs`.

mod browse;
mod cancel;
mod col;
mod hash;
mod highlight;
mod index;
mod mmap;
mod names;
mod persist;
mod query;
pub mod rank;
mod rules;
mod search;
mod store;
mod update;
pub mod walk;

#[cfg(test)]
mod tests;

pub use cancel::{Cancel, Cancelled};
pub use index::{Config, FileIndex};
pub use persist::{FileMeta, LoadError};
pub use rank::{Prefer, RankParams};
pub use rules::Rules;
#[cfg(feature = "parallel")]
pub use search::Rayon;
pub use search::{BrowseSort, FileHit, How, Kinds, ParallelFor, SearchOptions, SearchStats, Searcher, Serial};
pub use store::{Builder, Children, EntryId, EntryInfo, MAX_DEPTH, NONE, Snapshot, flags};
pub use update::{Event, UpdateStats, event_flags};
