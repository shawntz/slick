//! Stopping a walk early.
//!
//! A [`Cancel`] is shared between the thread that walks and any thread that wants it to stop. The
//! walker checks it once per folder, so a walk over a large tree stops within one folder listing
//! per walker thread. A stopped walk publishes nothing: the index keeps the snapshot it had.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// A flag that stops a walk. Set it from any thread with [`Cancel::cancel`].
#[derive(Debug)]
pub struct Cancel {
    stop: AtomicBool,
    /// Folder checks left before the flag sets itself, or `u64::MAX` when off.
    countdown: AtomicU64,
}

/// A walk stopped early because its [`Cancel`] was set. Nothing was published.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cancelled;

impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the walk was cancelled")
    }
}

impl std::error::Error for Cancelled {}

impl Default for Cancel {
    fn default() -> Self {
        Cancel::new()
    }
}

impl Cancel {
    /// A flag that is not set.
    pub const fn new() -> Cancel {
        Cancel {
            stop: AtomicBool::new(false),
            countdown: AtomicU64::new(u64::MAX),
        }
    }

    /// A flag that lets `folders` folder checks pass and stops the walk at the next one. For tests
    /// that stop a walk at a known point instead of racing a second thread.
    pub fn after(folders: u64) -> Cancel {
        let c = Cancel::new();
        c.cancel_after(folders);
        c
    }

    /// Stops every walk that checks this flag, at its next folder.
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
    }

    /// Lets `folders` more folder checks pass, then sets the flag. For tests.
    pub fn cancel_after(&self, folders: u64) {
        if folders == 0 {
            self.cancel();
        } else {
            self.countdown.store(folders.min(u64::MAX - 1), Ordering::Release);
        }
    }

    /// Clears the flag and any countdown, so the flag can stop another walk.
    pub fn reset(&self) {
        self.countdown.store(u64::MAX, Ordering::Release);
        self.stop.store(false, Ordering::Release);
    }

    /// True once the flag is set. Does not count as a folder check.
    pub fn is_cancelled(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    /// The walker's check before each folder: true when the walk must stop.
    #[inline]
    pub(crate) fn check(&self) -> bool {
        if self.stop.load(Ordering::Acquire) {
            return true;
        }
        if self.countdown.load(Ordering::Relaxed) == u64::MAX {
            return false;
        }
        let left = self.countdown.try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n != u64::MAX && n > 0).then(|| n - 1)
        });
        if left == Err(0) {
            self.cancel();
            return true;
        }
        false
    }
}

/// The flag of walks that cannot be cancelled.
pub(crate) static NEVER: Cancel = Cancel::new();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_countdown_sets_the_flag_after_that_many_checks() {
        let c = Cancel::after(3);
        assert!(!c.check());
        assert!(!c.check());
        assert!(!c.check());
        assert!(c.check(), "the fourth check stops");
        assert!(c.is_cancelled());
        assert!(c.check());
        c.reset();
        assert!(!c.is_cancelled() && !c.check());
        let now = Cancel::after(0);
        assert!(now.is_cancelled());
    }

    #[test]
    fn a_plain_flag_stops_only_once_set() {
        let c = Cancel::new();
        for _ in 0..100 {
            assert!(!c.check());
        }
        c.cancel();
        assert!(c.check() && c.is_cancelled());
        assert!(!NEVER.check());
    }
}
