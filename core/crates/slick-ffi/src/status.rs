//! Status codes and the panic guard shared by every exported function.

use slick_engine::EngineError;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Status codes returned by exported functions. Negative values are errors.
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlickStatus {
    /// Success.
    Ok = 0,
    /// A required pointer argument was NULL.
    NullPointer = -1,
    /// A string argument was not valid UTF-8.
    InvalidUtf8 = -2,
    /// Rust panicked. The panic was caught at the boundary and the process keeps running.
    Panic = -3,
    /// A lock was poisoned by an earlier panic. The handle must be rebuilt.
    Poisoned = -4,
    /// An argument is out of range, such as a string span outside its buffer.
    InvalidArgument = -5,
    /// The output buffer is too small; the call reports the size it needs.
    BufferTooSmall = -6,
    /// The data directory could not be created, read or written. For a folder listing, the folder
    /// could not be read.
    Io = -7,
    /// A walk stopped early because its cancel flag was set. Nothing was published.
    Cancelled = -8,
}

impl From<EngineError> for SlickStatus {
    fn from(e: EngineError) -> Self {
        match e {
            EngineError::Poisoned => SlickStatus::Poisoned,
            EngineError::Io(_) => SlickStatus::Io,
        }
    }
}

/// Runs `body` and turns a panic into `SlickStatus::Panic`.
///
/// Since Rust 1.81 a panic that unwinds out of an `extern "C"` function aborts the process. The
/// guard keeps a bug in one area from taking down a launcher that lives in the menu bar: the Swift
/// side gets an error it can show instead.
#[inline(always)]
pub(crate) fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(SlickStatus::Panic as i32)
}

/// `guard` for bodies that fail with a status: `Ok(n)` returns n, `Err(s)` returns s.
#[inline(always)]
pub(crate) fn guard_result(body: impl FnOnce() -> Result<i32, SlickStatus>) -> i32 {
    guard(|| body().unwrap_or_else(|s| s as i32))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_passes_the_value_through() {
        assert_eq!(guard(|| 7), 7);
        assert_eq!(guard_result(|| Err(SlickStatus::Io)), SlickStatus::Io as i32);
    }

    #[test]
    fn guard_turns_a_panic_into_a_status() {
        assert_eq!(guard(|| panic!("boom")), SlickStatus::Panic as i32);
    }
}
