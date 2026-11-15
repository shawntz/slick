//! Learning for ranking. Everything stays on the machine.
//!
//! - [`affinity`]: which item the user runs after each typed query, with prefix credit.
//! - [`zero_query`]: the Suggested list, a log-linear product of experts over frecency, recency,
//!   novelty and context features, with exponents learned online.
//! - [`frecency`]: the typed-ranking frecency signal.
//! - [`learner`]: one user's state, changed only by applying event-log records, so a state rebuilt
//!   from the [`log`] equals the live one.
//! - [`snapshot`]: the versioned dump that lets startup replay only the log's tail.
//!
//! The crate does no I/O and has no dependencies. The simulator that tunes the constants is the
//! `sim` example (`cargo run --release -p slick-predict --example sim`).

pub mod affinity;
pub mod context;
pub mod counts;
pub mod decay;
pub mod frecency;
pub mod hash;
pub mod learner;
pub mod log;
pub mod snapshot;
pub mod time;
pub mod zero_query;

pub use learner::{Execution, Learner, LearnerParams, Situation};
pub use log::Source;
