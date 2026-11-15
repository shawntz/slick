//! The root search engine: the catalog, the ranking contract, query sessions, suggestions,
//! learning with persistence, and the generic fuzzy indexes that features use.
//!
//! It combines `slick-match` (text tiers) with `slick-predict` (learned signals) under the ranking
//! contract in `docs/ARCHITECTURE.md` and owns its constants ([`rank`]). Pure Rust: the C ABI over
//! it lives in `slick-ffi`.

pub mod catalog;
pub mod context;
mod engine;
mod fuzzy;
mod index;
mod json;
pub mod rank;
mod session;
mod stats;
mod store;

pub use catalog::{Item, flags};
pub use context::{Context, audio};
pub use engine::{Engine, EngineError, EngineParams, SUGGESTIONS, StoreParams};
pub use fuzzy::FuzzyIndex;
pub use rank::{RankParams, kind};
pub use session::{FIELD_NONE, FIELD_USER_ALIAS, Hit, Session, hit_flags};
pub use slick_predict::Source;
pub use slick_predict::hash::fnv1a as key_of;
pub use store::pause_snapshots_for_tests;
