//! Time as the learning code sees it.
//!
//! The event log stores whole seconds since 2026-01-01T00:00:00Z in a `u32` (good until 2162).
//! The models work in minutes since the same epoch, as `f64`.

/// Unix time of 2026-01-01T00:00:00Z.
pub const EPOCH_UNIX: f64 = 1_767_225_600.0;

/// Minutes in a day.
pub const DAY: f64 = 1_440.0;

/// Seconds since the epoch for a Unix time, clamped to the `u32` range.
pub fn log_seconds(unix: f64) -> u32 {
    if unix.is_finite() {
        (unix - EPOCH_UNIX).clamp(0.0, u32::MAX as f64) as u32
    } else {
        0
    }
}

/// Model time (minutes since the epoch) for logged seconds.
pub fn minutes(log_seconds: u32) -> f64 {
    log_seconds as f64 / 60.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_is_new_year_2026() {
        // 2025-01-01T00:00:00Z is 1,735,689,600; 2025 has 365 days.
        assert_eq!(EPOCH_UNIX, 1_735_689_600.0 + 365.0 * 86_400.0);
        assert_eq!(log_seconds(EPOCH_UNIX + 90.5), 90);
        assert_eq!(log_seconds(0.0), 0);
        assert_eq!(log_seconds(f64::NAN), 0);
        assert_eq!(minutes(120), 2.0);
    }
}
