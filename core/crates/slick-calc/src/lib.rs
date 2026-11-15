//! The calculator behind root search: arithmetic, percentages, number bases, units, currency,
//! dates, durations and time zones.
//!
//! Pure Rust with no dependencies and no I/O on the evaluation path. The C ABI for it lives in
//! `slick-ffi/src/calc.rs`. See the crate README for the API contract.
//!
//! ```
//! use slick_calc::{evaluate, Answer, Context, Kind};
//!
//! let ctx = Context::new(1_763_200_000_000);
//! let mut answer = Answer::new();
//! assert!(evaluate("2 + 2", &ctx, &mut answer));
//! assert_eq!(answer.kind, Kind::Number);
//! assert_eq!(answer.main, "4");
//! assert!(!evaluate("safari", &ctx, &mut answer));
//! assert_eq!(answer.kind, Kind::None);
//! ```

#![forbid(unsafe_code)]
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod answer;
mod cal;
mod context;
mod currency;
mod format;
mod lex;
mod lexicon;
mod num;
mod parse;
mod places;
mod quick;
mod render;
mod tz;
mod units;
mod value;

pub use answer::{Alternate, Answer, Kind, MAX_ALTERNATES, Problem};
pub use context::{AngleUnit, Context, DateOrder, HourCycle};
pub use currency::Rates;
pub use tz::ZoneDb;

/// Queries longer than this many bytes are never calculations.
pub const MAX_QUERY_LEN: usize = 256;

/// The confidence at or above which an answer should claim the top of the results.
pub const CLAIMS_TOP: u8 = 80;

/// Evaluates `query` into `out`. Returns true when `out` holds an answer or a calculation error.
///
/// On false, `out.kind` is [`Kind::None`] and nothing was allocated. The call never panics and
/// never does I/O. After [`prepare`] it never waits on a lock. It is meant for every keystroke on
/// the main thread.
pub fn evaluate(query: &str, ctx: &Context, out: &mut Answer) -> bool {
    out.clear();
    let q = query.trim();
    if q.is_empty() || q.len() > MAX_QUERY_LEN || !quick::might_be_math(q) {
        return false;
    }
    let mut lexed = lex::Lexed::new();
    if !lex::lex(q, ctx.decimal, ctx.grouping, &mut lexed) {
        return false;
    }
    let env = value::Env::new(ctx);
    let Some(outcome) = parse::parse(q, &lexed, &env) else {
        return false;
    };
    render::render(&outcome, &env, out)
}

/// The cheap first check alone: false means `evaluate` would return false.
pub fn might_be_calculation(query: &str) -> bool {
    let q = query.trim();
    !q.is_empty() && q.len() <= MAX_QUERY_LEN && quick::might_be_math(q)
}

/// Builds the lookup tables now, so the first keystroke does not pay for it. Safe to call from
/// any thread, any number of times. Takes under a millisecond.
pub fn prepare() {
    lexicon::prepare();
}

/// Every IANA zone name the engine can refer to. [`ZoneDb::load_system`] loads these.
pub fn zone_names() -> &'static [&'static str] {
    places::zone_names()
}
