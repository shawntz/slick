//! The C ABI of the Slick core.
//!
//! This is the only crate built as a static library, and the only crate that exports symbols.
//! Every Rust area the app needs is exposed through one module here, so the app links exactly one
//! copy of Rust's standard library. cbindgen turns this crate into `include/slick_core.h`, which
//! `scripts/build-rust.sh` installs into the CoreBridge Swift package.
//!
//! Conventions. Keep them when you add a function:
//! - Every exported function is `extern "C"`, `#[unsafe(no_mangle)]` and named `slick_<area>_...`.
//! - Strings cross as a UTF-8 pointer plus a byte length. They are never NUL-terminated and Rust
//!   never takes ownership of them.
//! - The caller owns every buffer. Rust hands out heap memory only as opaque handles, and the query
//!   path allocates nothing.
//! - Every exported function returns an `i32`: zero or more is success (often a count or an id),
//!   below zero is a [`SlickStatus`]. Its body runs inside `guard`, so a panic comes back as
//!   `SLICK_STATUS_PANIC` instead of aborting the launcher. The one exception is
//!   [`slick_abi_version`], which cannot fail.
//! - Bump [`SLICK_ABI_VERSION`] whenever the generated header changes. Swift checks it at launch,
//!   so an app built against a newer header refuses a stale library.
//!
//! Item keys are the 64-bit FNV-1a hash (offset basis 0xcbf29ce484222325, prime 0x100000001b3) of
//! the item's id string in UTF-8, computed by the caller. Both sides assert the test vector in
//! [`SLICK_KEY_TEST_VALUE`].

mod args;
mod calc;
mod engine;
mod files;
mod index;
mod session;
mod status;
mod synthetic;

pub use args::{SLICK_LIST_SEPARATOR, SlickItem};
pub use calc::{
    SLICK_CALC_ANGLE_DEGREES, SLICK_CALC_ANGLE_RADIANS, SLICK_CALC_CLAIMS_TOP, SLICK_CALC_DATE_DAY_MONTH_YEAR,
    SLICK_CALC_DATE_MONTH_DAY_YEAR, SLICK_CALC_DATE_YEAR_MONTH_DAY, SLICK_CALC_HOURS_12, SLICK_CALC_HOURS_24,
    SLICK_CALC_KIND_CURRENCY, SLICK_CALC_KIND_DATE, SLICK_CALC_KIND_DURATION, SLICK_CALC_KIND_ERROR,
    SLICK_CALC_KIND_NONE, SLICK_CALC_KIND_NUMBER, SLICK_CALC_KIND_PERCENT, SLICK_CALC_KIND_QUANTITY,
    SLICK_CALC_KIND_TEXT, SLICK_CALC_KIND_TIME, SLICK_CALC_MAX_ALTERNATES, SLICK_CALC_MAX_QUERY_LEN,
    SLICK_CALC_PROBLEM_DIVISION_BY_ZERO, SLICK_CALC_PROBLEM_INCOMPATIBLE_UNITS, SLICK_CALC_PROBLEM_INVALID_DATE,
    SLICK_CALC_PROBLEM_NO_RATE, SLICK_CALC_PROBLEM_NO_RATES, SLICK_CALC_PROBLEM_NO_TIME_ZONES, SLICK_CALC_PROBLEM_NONE,
    SLICK_CALC_PROBLEM_NOT_REAL, SLICK_CALC_PROBLEM_NOT_WHOLE, SLICK_CALC_PROBLEM_OVERFLOW,
    SLICK_CALC_PROBLEM_UNDEFINED, SLICK_CALC_PROBLEM_UNKNOWN_ZONE, SLICK_CALC_PROBLEM_UNSUPPORTED,
    SLICK_CALC_TEXT_ALTERNATE, SLICK_CALC_TEXT_ALTERNATE_LABEL, SLICK_CALC_TEXT_COPY, SLICK_CALC_TEXT_MAIN,
    SLICK_CALC_TEXT_NOTE, SlickCalc, SlickCalcContext, SlickCalcRates, SlickCalcResult, SlickCalcZones,
};
pub use engine::{
    SLICK_CONTEXT_FOCUS, SLICK_CONTEXT_ON_BATTERY, SLICK_CONTEXT_SESSION_START, SlickContext, SlickEngine,
    SlickLearningSummary, SlickSuggestion,
};
pub use files::{
    SLICK_FILES_ENTRY_DIR, SLICK_FILES_ENTRY_HIDDEN, SLICK_FILES_ENTRY_PACKAGE, SLICK_FILES_ENTRY_ROOT,
    SLICK_FILES_ENTRY_SYMLINK, SLICK_FILES_ENTRY_UNREADABLE, SLICK_FILES_HOW_ANCESTOR, SLICK_FILES_HOW_BROWSE,
    SLICK_FILES_HOW_EXTENSION, SLICK_FILES_HOW_FILTER, SLICK_FILES_HOW_NAME, SLICK_FILES_HOW_TYPO,
    SLICK_FILES_KINDS_ALL, SLICK_FILES_KINDS_FILES, SLICK_FILES_KINDS_FOLDERS, SLICK_FILES_LOAD_CORRUPT,
    SLICK_FILES_LOAD_IO, SLICK_FILES_LOAD_MISMATCH, SLICK_FILES_LOAD_MISSING, SLICK_FILES_LOAD_OK,
    SLICK_FILES_LOAD_VERSION, SLICK_FILES_NONE, SLICK_FILES_PREFER_FILES, SLICK_FILES_PREFER_FOLDERS,
    SLICK_FILES_PREFER_NEITHER, SLICK_FILES_RULES_INCLUDE_HIDDEN, SLICK_FILES_RULES_ONE_FILESYSTEM,
    SLICK_FILES_RULES_RECOMMENDED, SLICK_FILES_SEARCH_HIDDEN, SLICK_FILES_SEARCH_NO_TYPO, SLICK_FILES_SEARCH_SERIAL,
    SLICK_FILES_SORT_MODIFIED, SLICK_FILES_SORT_NAME, SlickFileEntry, SlickFileHit, SlickFiles, SlickFilesConfig,
    SlickFilesEvent, SlickFilesInfo, SlickFilesOpenInfo, SlickFilesOptions, SlickFilesSearchStats, SlickFilesSession,
    SlickFilesSnapshot, SlickFilesUpdateStats, SlickFilesWalkStats,
};
pub use index::SlickIndex;
pub use session::{SlickHit, SlickRange, SlickSession};
pub use status::SlickStatus;
use status::guard;

/// The version of this C ABI. Bump it whenever the generated header changes.
pub const SLICK_ABI_VERSION: u32 = 3;

/// Key test vector: the 64-bit FNV-1a hash (offset basis 0xcbf29ce484222325, prime
/// 0x100000001b3) of the UTF-8 item id "app:com.example.Editor" is 0xb5f6c1de724e0e9e. Of "" it
/// is 0xcbf29ce484222325, of "a" 0xaf63dc4c8601ec8c. Swift computes keys and asserts this vector.
pub const SLICK_KEY_TEST_VALUE: u64 = 0xb5f6_c1de_724e_0e9e;

/// `SlickItem.flags`: never shown in the zero-query suggestions.
pub const SLICK_ITEM_NO_SUGGEST: u32 = 1;
/// `SlickItem.flags`: executions are not learned.
pub const SLICK_ITEM_NO_LEARN: u32 = 2;

/// `SlickItem.kind`: anything else.
pub const SLICK_KIND_OTHER: u8 = 0;
/// `SlickItem.kind`: an application.
pub const SLICK_KIND_APP: u8 = 1;
/// `SlickItem.kind`: a command.
pub const SLICK_KIND_COMMAND: u8 = 2;
/// `SlickItem.kind`: a file or folder.
pub const SLICK_KIND_FILE: u8 = 3;
/// `SlickItem.kind`: a settings pane.
pub const SLICK_KIND_SETTING: u8 = 4;
/// `SlickItem.kind`: a contact.
pub const SLICK_KIND_CONTACT: u8 = 5;

/// `slick_engine_record` source: picked from typed results.
pub const SLICK_SOURCE_TYPED: u8 = 0;
/// `slick_engine_record` source: picked from the suggestions.
pub const SLICK_SOURCE_SUGGESTION: u8 = 1;
/// `slick_engine_record` source: run by its own hotkey.
pub const SLICK_SOURCE_HOTKEY: u8 = 2;
/// `slick_engine_record` source: run through a user alias.
pub const SLICK_SOURCE_ALIAS: u8 = 3;
/// `slick_engine_record` source: a fallback action.
pub const SLICK_SOURCE_FALLBACK: u8 = 4;

/// `SlickHit.flags`: a user alias matched.
pub const SLICK_HIT_ALIAS: u8 = 1;
/// `SlickHit.flags`: the learned band.
pub const SLICK_HIT_LEARNED: u8 = 2;
/// `SlickHit.flags`: query affinity below the band lifted the hit.
pub const SLICK_HIT_AFFINITY: u8 = 4;

/// `SlickContext.audio_route`: built-in speakers.
pub const SLICK_AUDIO_BUILT_IN: u8 = 0;
/// `SlickContext.audio_route`: wired headphones.
pub const SLICK_AUDIO_HEADPHONES: u8 = 1;
/// `SlickContext.audio_route`: Bluetooth.
pub const SLICK_AUDIO_BLUETOOTH: u8 = 2;
/// `SlickContext.audio_route`: USB.
pub const SLICK_AUDIO_USB: u8 = 3;
/// `SlickContext.audio_route`: AirPlay or anything else.
pub const SLICK_AUDIO_OTHER: u8 = 4;

/// Returns `SLICK_ABI_VERSION`. The app compares it with the header it was compiled against, so a
/// stale static library fails loudly at launch instead of misbehaving later.
#[unsafe(no_mangle)]
pub extern "C" fn slick_abi_version() -> u32 {
    SLICK_ABI_VERSION
}

/// Does nothing and returns `SLICK_STATUS_OK`. The selftest calls it to prove that the static
/// library is linked and callable, and it shows the shape every exported function follows.
#[unsafe(no_mangle)]
pub extern "C" fn slick_noop() -> i32 {
    guard(|| SlickStatus::Ok as i32)
}

/// Panics inside the guard and returns `SLICK_STATUS_PANIC`. Tests call it to prove that a Rust
/// panic comes back as a status instead of aborting the process.
#[unsafe(no_mangle)]
pub extern "C" fn slick_debug_panic() -> i32 {
    guard(|| panic!("slick_debug_panic was called"))
}

#[cfg(test)]
mod tests;
