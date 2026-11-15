//! Time zone rules read from the system's compiled zoneinfo, the TZif format of RFC 8536.
//!
//! The engine never reads files while it evaluates. The caller loads a [`ZoneDb`] once, off the
//! main thread, and passes it in the context. Instants past a zone's last transition follow the
//! POSIX TZ rule in the file's footer.

use crate::cal;
use crate::places;
use std::path::Path;

/// A zone abbreviation such as "JST" or "+0530", up to 8 bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub(crate) struct Abbr {
    b: [u8; 8],
    len: u8,
}

impl Abbr {
    pub(crate) fn new(s: &str) -> Abbr {
        let mut b = [0u8; 8];
        let mut len = 0;
        for (slot, c) in b.iter_mut().zip(s.bytes()) {
            *slot = c;
            len += 1;
        }
        Abbr { b, len }
    }

    pub(crate) fn as_str(&self) -> &str {
        core::str::from_utf8(self.b.get(..usize::from(self.len)).unwrap_or(&[])).unwrap_or("")
    }
}

/// One local time type: an offset east of UTC in seconds and its abbreviation.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct TType {
    pub off: i32,
    pub abbr: Abbr,
}

#[derive(Clone, Copy, Debug)]
enum RuleDay {
    /// `Jn`: day 1 to 365, February 29 never counted.
    Julian1(u16),
    /// `n`: day 0 to 365, leap days counted.
    Julian0(u16),
    /// `Mm.w.d`: weekday `d` (0 is Sunday) of week `w` (5 is the last) of month `m`.
    Mwd(u8, u8, u8),
}

#[derive(Clone, Copy, Debug)]
struct Rule {
    day: RuleDay,
    /// Seconds after local midnight; may be negative or past 24 hours.
    time: i32,
}

#[derive(Clone, Copy, Debug)]
struct Posix {
    std: TType,
    dst: Option<(TType, Rule, Rule)>,
}

/// The rules of one zone.
#[derive(Clone, Debug)]
pub(crate) struct Zone {
    trans: Vec<i64>,
    idx: Vec<u8>,
    types: Vec<TType>,
    rule: Option<Posix>,
}

impl Zone {
    /// The local time type at a UTC instant in seconds.
    pub(crate) fn at(&self, utc: i64) -> TType {
        let first = self.types.first().copied().unwrap_or_default();
        let n = self.trans.partition_point(|&t| t <= utc);
        if n == 0 {
            return if self.trans.is_empty() {
                self.rule.map_or(first, |r| r.at(utc))
            } else {
                first
            };
        }
        if n == self.trans.len()
            && let Some(rule) = self.rule
        {
            return rule.at(utc);
        }
        let i = self.idx.get(n - 1).copied().unwrap_or(0);
        self.types.get(usize::from(i)).copied().unwrap_or(first)
    }

    /// The UTC instant of a wall-clock time in this zone. In a gap the earlier offset wins.
    pub(crate) fn to_utc(&self, local: i64) -> i64 {
        let guess = local.saturating_sub(i64::from(self.at(local).off));
        let off = self.at(guess).off;
        let utc = local.saturating_sub(i64::from(off));
        let check = self.at(utc).off;
        if check == off {
            utc
        } else {
            local.saturating_sub(i64::from(check))
        }
    }
}

impl Posix {
    fn at(&self, utc: i64) -> TType {
        let Some((dst, start, end)) = self.dst else {
            return self.std;
        };
        let year = cal::ymd(day_of(utc.saturating_add(i64::from(self.std.off)))).0;
        let s = start.utc(year, self.std.off);
        let e = end.utc(year, dst.off);
        let in_dst = if s < e {
            utc >= s && utc < e
        } else {
            !(utc >= e && utc < s)
        };
        if in_dst { dst } else { self.std }
    }
}

fn day_of(secs: i64) -> i32 {
    let d = secs.div_euclid(cal::SECS_PER_DAY);
    i32::try_from(d.clamp(-719_162, 2_932_896)).unwrap_or(0)
}

impl Rule {
    /// The UTC instant of this transition in `year`, given the offset in force before it.
    fn utc(&self, year: i32, off_before: i32) -> i64 {
        let day = match self.day {
            RuleDay::Julian1(n) => {
                let n = i32::from(n);
                let leap_shift = i32::from(cal::is_leap(year) && n >= 60);
                cal::days_from_ymd(year, 1, 1).map(|d| d + n - 1 + leap_shift)
            }
            RuleDay::Julian0(n) => cal::days_from_ymd(year, 1, 1).map(|d| d + i32::from(n)),
            RuleDay::Mwd(m, w, d) => {
                let m = i32::from(m);
                let wd = (i32::from(d) + 6) % 7; // POSIX 0 is Sunday; ours 6 is Sunday.
                cal::days_from_ymd(year, m, 1).map(|first| {
                    let offset = (wd - cal::weekday(first)).rem_euclid(7);
                    let mut day = first + offset + 7 * (i32::from(w) - 1);
                    while cal::ymd(day).1 != m {
                        day -= 7;
                    }
                    day
                })
            }
        };
        let day = day.unwrap_or(0);
        i64::from(day) * cal::SECS_PER_DAY + i64::from(self.time) - i64::from(off_before)
    }
}

fn be32(b: &[u8], i: usize) -> Option<i32> {
    let s = b.get(i..i + 4)?;
    Some(i32::from_be_bytes([*s.first()?, *s.get(1)?, *s.get(2)?, *s.get(3)?]))
}

fn be64(b: &[u8], i: usize) -> Option<i64> {
    let s = b.get(i..i + 8)?;
    let mut a = [0u8; 8];
    a.copy_from_slice(s);
    Some(i64::from_be_bytes(a))
}

fn count(b: &[u8], i: usize) -> Option<usize> {
    usize::try_from(be32(b, i)?).ok().filter(|&n| n < 100_000)
}

/// Parses a TZif file. None when it is malformed.
pub(crate) fn parse_tzif(b: &[u8]) -> Option<Zone> {
    if b.get(..4)? != b"TZif" {
        return None;
    }
    let version = *b.get(4)?;
    let (isut, isstd, leap, timecnt, typecnt, charcnt) = (
        count(b, 20)?,
        count(b, 24)?,
        count(b, 28)?,
        count(b, 32)?,
        count(b, 36)?,
        count(b, 40)?,
    );
    let v1_len = timecnt * 5 + typecnt * 6 + charcnt + leap * 8 + isstd + isut;
    if version >= b'2' {
        let h = 44 + v1_len;
        if b.get(h..h + 4)? != b"TZif" {
            return None;
        }
        let (isut, isstd, leap, timecnt, typecnt, charcnt) = (
            count(b, h + 20)?,
            count(b, h + 24)?,
            count(b, h + 28)?,
            count(b, h + 32)?,
            count(b, h + 36)?,
            count(b, h + 40)?,
        );
        let data = h + 44;
        let mut zone = parse_block(b, data, timecnt, typecnt, charcnt, 8)?;
        let footer = data + timecnt * 9 + typecnt * 6 + charcnt + leap * 12 + isstd + isut;
        if b.get(footer) == Some(&b'\n') {
            let rest = b.get(footer + 1..)?;
            let end = rest.iter().position(|&c| c == b'\n')?;
            let tz = core::str::from_utf8(rest.get(..end)?).ok()?;
            zone.rule = parse_posix(tz);
        }
        Some(zone)
    } else {
        parse_block(b, 44, timecnt, typecnt, charcnt, 4)
    }
}

fn parse_block(b: &[u8], at: usize, timecnt: usize, typecnt: usize, charcnt: usize, width: usize) -> Option<Zone> {
    if typecnt == 0 {
        return None;
    }
    let mut trans = Vec::with_capacity(timecnt);
    for k in 0..timecnt {
        let i = at + k * width;
        trans.push(if width == 8 {
            be64(b, i)?
        } else {
            i64::from(be32(b, i)?)
        });
    }
    let idx_at = at + timecnt * width;
    let idx = b.get(idx_at..idx_at + timecnt)?.to_vec();
    let types_at = idx_at + timecnt;
    let chars_at = types_at + typecnt * 6;
    let chars = b.get(chars_at..chars_at + charcnt)?;
    let mut types = Vec::with_capacity(typecnt);
    for k in 0..typecnt {
        let i = types_at + k * 6;
        let off = be32(b, i)?;
        let ai = usize::from(*b.get(i + 5)?);
        let tail = chars.get(ai..).unwrap_or(&[]);
        let end = tail.iter().position(|&c| c == 0).unwrap_or(tail.len());
        let abbr = core::str::from_utf8(tail.get(..end).unwrap_or(&[])).unwrap_or("");
        types.push(TType {
            off,
            abbr: Abbr::new(abbr),
        });
    }
    if idx.iter().any(|&i| usize::from(i) >= typecnt) {
        return None;
    }
    Some(Zone {
        trans,
        idx,
        types,
        rule: None,
    })
}

struct Cursor<'a> {
    s: &'a [u8],
    i: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn name(&mut self) -> Option<Abbr> {
        if self.peek()? == b'<' {
            let start = self.i + 1;
            let end = start + self.s.get(start..)?.iter().position(|&c| c == b'>')?;
            self.i = end + 1;
            return Some(Abbr::new(core::str::from_utf8(self.s.get(start..end)?).ok()?));
        }
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_alphabetic()) {
            self.i += 1;
        }
        if self.i - start < 3 {
            return None;
        }
        Some(Abbr::new(core::str::from_utf8(self.s.get(start..self.i)?).ok()?))
    }

    fn number(&mut self) -> Option<i32> {
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        core::str::from_utf8(self.s.get(start..self.i)?).ok()?.parse().ok()
    }

    /// `[+-]hh[:mm[:ss]]` in seconds.
    fn hms(&mut self) -> Option<i32> {
        let sign = match self.peek() {
            Some(b'-') => {
                self.i += 1;
                -1
            }
            Some(b'+') => {
                self.i += 1;
                1
            }
            _ => 1,
        };
        let mut secs = self.number()?.checked_mul(3600)?;
        for scale in [60, 1] {
            if self.peek() != Some(b':') {
                break;
            }
            self.i += 1;
            secs = secs.checked_add(self.number()?.checked_mul(scale)?)?;
        }
        Some(sign * secs)
    }

    fn rule(&mut self) -> Option<Rule> {
        let day = match self.peek()? {
            b'M' => {
                self.i += 1;
                let m = self.number()?;
                (self.peek()? == b'.').then_some(())?;
                self.i += 1;
                let w = self.number()?;
                (self.peek()? == b'.').then_some(())?;
                self.i += 1;
                let d = self.number()?;
                if !(1..=12).contains(&m) || !(1..=5).contains(&w) || !(0..=6).contains(&d) {
                    return None;
                }
                RuleDay::Mwd(m as u8, w as u8, d as u8)
            }
            b'J' => {
                self.i += 1;
                let n = self.number()?;
                RuleDay::Julian1(u16::try_from(n).ok().filter(|n| (1..=365).contains(n))?)
            }
            _ => RuleDay::Julian0(u16::try_from(self.number()?).ok().filter(|&n| n <= 365)?),
        };
        let time = if self.peek() == Some(b'/') {
            self.i += 1;
            self.hms()?
        } else {
            7200
        };
        Some(Rule { day, time })
    }
}

/// Parses a POSIX TZ string such as "CET-1CEST,M3.5.0,M10.5.0/3".
fn parse_posix(s: &str) -> Option<Posix> {
    let mut c = Cursor { s: s.as_bytes(), i: 0 };
    let std_abbr = c.name()?;
    let std_off = -c.hms()?;
    let std = TType {
        off: std_off,
        abbr: std_abbr,
    };
    if c.peek().is_none() {
        return Some(Posix { std, dst: None });
    }
    let dst_abbr = c.name()?;
    let dst_off = match c.peek() {
        Some(b',') | None => std_off + 3600,
        _ => -c.hms()?,
    };
    let dst = TType {
        off: dst_off,
        abbr: dst_abbr,
    };
    let (start, end) = if c.peek() == Some(b',') {
        c.i += 1;
        let start = c.rule()?;
        (c.peek()? == b',').then_some(())?;
        c.i += 1;
        (start, c.rule()?)
    } else {
        (
            Rule {
                day: RuleDay::Mwd(3, 2, 0),
                time: 7200,
            },
            Rule {
                day: RuleDay::Mwd(11, 1, 0),
                time: 7200,
            },
        )
    };
    Some(Posix {
        std,
        dst: Some((dst, start, end)),
    })
}

/// Time zone rules for every zone the engine can name, loaded once by the caller.
#[derive(Clone, Debug, Default)]
pub struct ZoneDb {
    /// Indexed by [`places::zone_id`].
    known: Vec<Option<Zone>>,
    /// Zones outside the engine's own list, such as an unusual local zone.
    extra: Vec<(String, Zone)>,
}

/// Where macOS keeps the compiled zoneinfo. The second is the target of the first's symlink.
const SYSTEM_DIRS: [&str; 2] = ["/usr/share/zoneinfo", "/var/db/timezone/zoneinfo"];

impl ZoneDb {
    /// An empty database. Time zone queries answer that data is not loaded.
    pub fn new() -> ZoneDb {
        ZoneDb::default()
    }

    /// Reads every zone the engine names, plus `extra` zone names such as the local zone, from
    /// the system's zoneinfo. Does file I/O: call it off the main thread.
    pub fn load_system(extra: &[&str]) -> ZoneDb {
        for dir in SYSTEM_DIRS {
            let db = ZoneDb::load_dir(Path::new(dir), extra);
            if !db.is_empty() {
                return db;
            }
        }
        ZoneDb::new()
    }

    /// Reads zones from a zoneinfo directory.
    pub fn load_dir(dir: &Path, extra: &[&str]) -> ZoneDb {
        let mut db = ZoneDb::new();
        let names = places::zone_names();
        db.known = vec![None; names.len()];
        for (i, name) in names.iter().enumerate() {
            if let Some(zone) = read_zone(dir, name)
                && let Some(slot) = db.known.get_mut(i)
            {
                *slot = Some(zone);
            }
        }
        for name in extra {
            if places::zone_id(name).is_none()
                && let Some(zone) = read_zone(dir, name)
            {
                db.extra.push(((*name).to_owned(), zone));
            }
        }
        db
    }

    /// Adds one zone from TZif bytes. False when the bytes are not a TZif file.
    pub fn insert_tzif(&mut self, name: &str, bytes: &[u8]) -> bool {
        let Some(zone) = parse_tzif(bytes) else { return false };
        match places::zone_id(name) {
            Some(id) => {
                let id = usize::from(id);
                if self.known.len() <= id {
                    self.known.resize(id + 1, None);
                }
                if let Some(slot) = self.known.get_mut(id) {
                    *slot = Some(zone);
                }
            }
            None => self.extra.push((name.to_owned(), zone)),
        }
        true
    }

    /// The number of zones loaded.
    pub fn len(&self) -> usize {
        self.known.iter().filter(|z| z.is_some()).count() + self.extra.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// True when the zone is loaded.
    pub fn contains(&self, name: &str) -> bool {
        self.by_name(name).is_some()
    }

    pub(crate) fn get(&self, id: u16) -> Option<&Zone> {
        self.known.get(usize::from(id))?.as_ref()
    }

    pub(crate) fn by_name(&self, name: &str) -> Option<&Zone> {
        if let Some(id) = places::zone_id(name) {
            return self.get(id);
        }
        self.extra.iter().find(|(n, _)| n == name).map(|(_, z)| z)
    }
}

fn read_zone(dir: &Path, name: &str) -> Option<Zone> {
    if name.is_empty() || name.contains("..") || name.starts_with('/') {
        return None;
    }
    let bytes = std::fs::read(dir.join(name)).ok()?;
    parse_tzif(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posix_rules() {
        let p = parse_posix("EST5EDT,M3.2.0,M11.1.0");
        assert!(p.is_some());
        let Some(p) = p else { return };
        // 2026-07-01 12:00 UTC is EDT, 2026-01-15 12:00 UTC is EST.
        let july = i64::from(cal::days_from_ymd(2026, 7, 1).unwrap_or(0)) * 86_400 + 43_200;
        let jan = i64::from(cal::days_from_ymd(2026, 1, 15).unwrap_or(0)) * 86_400 + 43_200;
        assert_eq!(p.at(july).off, -4 * 3600);
        assert_eq!(p.at(jan).off, -5 * 3600);
        assert_eq!(p.at(july).abbr.as_str(), "EDT");
        // Southern hemisphere.
        let syd = parse_posix("AEST-10AEDT,M10.1.0,M4.1.0/3");
        assert_eq!(syd.map(|p| p.at(jan).off), Some(11 * 3600));
        assert_eq!(syd.map(|p| p.at(july).off), Some(10 * 3600));
        // Quoted names and no DST.
        let ist = parse_posix("<+0530>-5:30");
        assert_eq!(ist.map(|p| p.at(jan).off), Some(19_800));
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_tzif(b"").is_none());
        assert!(parse_tzif(b"TZif2\0\0\0").is_none());
        assert!(parse_posix("").is_none());
        assert!(parse_posix("EST5EDT,M13.2.0,M11.1.0").is_none());
    }
}
