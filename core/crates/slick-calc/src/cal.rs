//! Proleptic Gregorian calendar arithmetic on day numbers since 1970-01-01.

pub(crate) const SECS_PER_DAY: i64 = 86_400;

/// Day numbers stay inside years 1 to 9999.
const MIN_DAY: i64 = -719_162;
const MAX_DAY: i64 = 2_932_896;

pub(crate) const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

pub(crate) const WEEKDAYS: [&str; 7] = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
];

pub(crate) fn is_leap(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub(crate) fn days_in_month(y: i32, m: i32) -> i32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(y) => 29,
        2 => 28,
        _ => 0,
    }
}

/// The day number of a valid date in years 1 to 9999.
pub(crate) fn days_from_ymd(y: i32, m: i32, d: i32) -> Option<i32> {
    if !(1..=9999).contains(&y) || !(1..=12).contains(&m) || d < 1 || d > days_in_month(y, m) {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = i64::from(if m <= 2 { y - 1 } else { y });
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(m);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    i32::try_from(era * 146_097 + doe - 719_468).ok()
}

/// Year, month and day of a day number.
pub(crate) fn ymd(days: i32) -> (i32, i32, i32) {
    let z = i64::from(days) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y as i32, m as i32, d as i32)
}

/// Monday is 0, Sunday is 6.
pub(crate) fn weekday(days: i32) -> i32 {
    (i64::from(days) + 3).rem_euclid(7) as i32
}

pub(crate) fn valid_day(days: i64) -> Option<i32> {
    if (MIN_DAY..=MAX_DAY).contains(&days) {
        i32::try_from(days).ok()
    } else {
        None
    }
}

/// Adds months, clamping the day to the target month's length: Jan 31 plus one month is Feb 28.
pub(crate) fn add_months(days: i32, months: i64) -> Option<i32> {
    let (y, m, d) = ymd(days);
    let total = i64::from(y) * 12 + i64::from(m - 1) + months;
    let ny = i32::try_from(total.div_euclid(12)).ok()?;
    let nm = (total.rem_euclid(12) + 1) as i32;
    let nd = d.min(days_in_month(ny, nm));
    days_from_ymd(ny, nm, nd)
}

/// Easter Sunday in the Gregorian calendar, by the anonymous Gregorian algorithm.
pub(crate) fn easter(y: i32) -> Option<i32> {
    let a = y % 19;
    let b = y / 100;
    let c = y % 100;
    let d = b / 4;
    let e = b % 4;
    let f = (b + 8) / 25;
    let g = (b - f + 1) / 3;
    let h = (19 * a + b - d - g + 15) % 30;
    let i = c / 4;
    let k = c % 4;
    let l = (32 + 2 * e + 2 * i - h - k) % 7;
    let m = (a + 11 * h + 22 * l) / 451;
    let month = (h + l - 7 * m + 114) / 31;
    let day = (h + l - 7 * m + 114) % 31 + 1;
    days_from_ymd(y, month, day)
}

/// The `n`th given weekday of a month, such as the fourth Thursday of November.
pub(crate) fn nth_weekday(y: i32, m: i32, wd: i32, n: i32) -> Option<i32> {
    let first = days_from_ymd(y, m, 1)?;
    let offset = (wd - weekday(first)).rem_euclid(7);
    let day = first + offset + 7 * (n - 1);
    if ymd(day).1 == m { Some(day) } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_dates() {
        for days in [-719_162, -1, 0, 1, 10_957, 20_407, 2_932_896] {
            let (y, m, d) = ymd(days);
            assert_eq!(days_from_ymd(y, m, d), Some(days));
        }
        assert_eq!(days_from_ymd(1970, 1, 1), Some(0));
        assert_eq!(days_from_ymd(2026, 2, 29), None);
        assert_eq!(weekday(0), 3, "1970-01-01 was a Thursday");
    }

    #[test]
    fn month_arithmetic_clamps() {
        let jan31 = days_from_ymd(2026, 1, 31).unwrap_or(0);
        assert_eq!(add_months(jan31, 1).map(ymd), Some((2026, 2, 28)));
        assert_eq!(add_months(jan31, -2).map(ymd), Some((2025, 11, 30)));
    }

    #[test]
    fn holidays() {
        assert_eq!(easter(2026).map(ymd), Some((2026, 4, 5)));
        assert_eq!(nth_weekday(2026, 11, 3, 4).map(ymd), Some((2026, 11, 26)));
    }
}
