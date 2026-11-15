//! Places and zone names: the city table in `data/places.txt` and the abbreviations people type.

use std::sync::OnceLock;

static DATA: &str = include_str!("data/places.txt");

/// What a zone word stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ZoneWord {
    /// A fixed offset east of UTC in seconds, such as PST or CET.
    Fixed(i32),
    /// A region's rules, such as "pacific time".
    Iana(&'static str),
}

/// Zone abbreviations and region names. An abbreviation that names standard or daylight time
/// is that fixed offset: "9am pst" is UTC-8 even in July. Generic names follow the region's
/// rules. Where an abbreviation is ambiguous, the most common reading in English wins: CST is
/// US Central, IST is India.
pub(crate) static ZONE_WORDS: &[(&str, ZoneWord)] = &[
    ("utc", ZoneWord::Fixed(0)),
    ("gmt", ZoneWord::Fixed(0)),
    ("z", ZoneWord::Fixed(0)),
    ("zulu", ZoneWord::Fixed(0)),
    ("est", ZoneWord::Fixed(-5 * 3600)),
    ("edt", ZoneWord::Fixed(-4 * 3600)),
    ("cst", ZoneWord::Fixed(-6 * 3600)),
    ("cdt", ZoneWord::Fixed(-5 * 3600)),
    ("mst", ZoneWord::Fixed(-7 * 3600)),
    ("mdt", ZoneWord::Fixed(-6 * 3600)),
    ("pst", ZoneWord::Fixed(-8 * 3600)),
    ("pdt", ZoneWord::Fixed(-7 * 3600)),
    ("akst", ZoneWord::Fixed(-9 * 3600)),
    ("akdt", ZoneWord::Fixed(-8 * 3600)),
    ("hst", ZoneWord::Fixed(-10 * 3600)),
    ("ast", ZoneWord::Fixed(-4 * 3600)),
    ("adt", ZoneWord::Fixed(-3 * 3600)),
    ("nst", ZoneWord::Fixed(-(3 * 3600 + 1800))),
    ("ndt", ZoneWord::Fixed(-(2 * 3600 + 1800))),
    ("brt", ZoneWord::Fixed(-3 * 3600)),
    ("art", ZoneWord::Fixed(-3 * 3600)),
    ("wet", ZoneWord::Fixed(0)),
    ("west", ZoneWord::Fixed(3600)),
    ("bst", ZoneWord::Fixed(3600)),
    ("ist", ZoneWord::Fixed(5 * 3600 + 1800)),
    ("cet", ZoneWord::Fixed(3600)),
    ("cest", ZoneWord::Fixed(2 * 3600)),
    ("eet", ZoneWord::Fixed(2 * 3600)),
    ("eest", ZoneWord::Fixed(3 * 3600)),
    ("msk", ZoneWord::Fixed(3 * 3600)),
    ("sast", ZoneWord::Fixed(2 * 3600)),
    ("cat", ZoneWord::Fixed(2 * 3600)),
    ("eat", ZoneWord::Fixed(3 * 3600)),
    ("wat", ZoneWord::Fixed(3600)),
    ("gst", ZoneWord::Fixed(4 * 3600)),
    ("pkt", ZoneWord::Fixed(5 * 3600)),
    ("ict", ZoneWord::Fixed(7 * 3600)),
    ("wib", ZoneWord::Fixed(7 * 3600)),
    ("sgt", ZoneWord::Fixed(8 * 3600)),
    ("hkt", ZoneWord::Fixed(8 * 3600)),
    ("pht", ZoneWord::Fixed(8 * 3600)),
    ("awst", ZoneWord::Fixed(8 * 3600)),
    ("jst", ZoneWord::Fixed(9 * 3600)),
    ("kst", ZoneWord::Fixed(9 * 3600)),
    ("acst", ZoneWord::Fixed(9 * 3600 + 1800)),
    ("acdt", ZoneWord::Fixed(10 * 3600 + 1800)),
    ("aest", ZoneWord::Fixed(10 * 3600)),
    ("aedt", ZoneWord::Fixed(11 * 3600)),
    ("nzst", ZoneWord::Fixed(12 * 3600)),
    ("nzdt", ZoneWord::Fixed(13 * 3600)),
    ("pt", ZoneWord::Iana("America/Los_Angeles")),
    ("pacific", ZoneWord::Iana("America/Los_Angeles")),
    ("pacific time", ZoneWord::Iana("America/Los_Angeles")),
    ("mt", ZoneWord::Iana("America/Denver")),
    ("mountain", ZoneWord::Iana("America/Denver")),
    ("mountain time", ZoneWord::Iana("America/Denver")),
    ("ct", ZoneWord::Iana("America/Chicago")),
    ("central", ZoneWord::Iana("America/Chicago")),
    ("central time", ZoneWord::Iana("America/Chicago")),
    ("et", ZoneWord::Iana("America/New_York")),
    ("eastern", ZoneWord::Iana("America/New_York")),
    ("eastern time", ZoneWord::Iana("America/New_York")),
    ("aet", ZoneWord::Iana("Australia/Sydney")),
    ("uk time", ZoneWord::Iana("Europe/London")),
    ("central european time", ZoneWord::Iana("Europe/Paris")),
];

pub(crate) struct Place {
    /// The name shown in answers.
    pub name: &'static str,
    pub zone: u16,
}

pub(crate) struct Places {
    pub places: Vec<Place>,
    /// Every name of every place as written, with the index of its place.
    pub names: Vec<(&'static str, u16)>,
    /// Sorted, unique IANA zone names.
    pub zones: Vec<&'static str>,
}

fn parse() -> Places {
    let mut rows: Vec<(Vec<&'static str>, &'static str)> = Vec::new();
    for line in DATA.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((names, zone)) = line.split_once('|') else {
            continue;
        };
        let names: Vec<&'static str> = names.split(';').map(str::trim).filter(|n| !n.is_empty()).collect();
        if names.is_empty() {
            continue;
        }
        rows.push((names, zone.trim()));
    }
    let mut zones: Vec<&'static str> = rows.iter().map(|r| r.1).collect();
    for (_, w) in ZONE_WORDS {
        if let ZoneWord::Iana(z) = w {
            zones.push(z);
        }
    }
    zones.sort_unstable();
    zones.dedup();
    let mut places = Vec::with_capacity(rows.len());
    let mut names = Vec::new();
    for (names_of, zone) in rows {
        let Ok(zi) = zones.binary_search(&zone) else { continue };
        let (Ok(zone), Ok(index)) = (u16::try_from(zi), u16::try_from(places.len())) else {
            continue;
        };
        let display = names_of.first().copied().unwrap_or("");
        // "Victoria, Seychelles" shows as "Victoria".
        let shown = display.split(',').next().unwrap_or(display).trim();
        places.push(Place { name: shown, zone });
        for n in names_of {
            names.push((n, index));
        }
    }
    Places { places, names, zones }
}

pub(crate) fn get() -> &'static Places {
    static PLACES: OnceLock<Places> = OnceLock::new();
    PLACES.get_or_init(parse)
}

/// Every IANA zone the engine can name, sorted.
pub(crate) fn zone_names() -> &'static [&'static str] {
    &get().zones
}

pub(crate) fn zone_id(name: &str) -> Option<u16> {
    let i = get().zones.binary_search(&name).ok()?;
    u16::try_from(i).ok()
}

pub(crate) fn zone_name(id: u16) -> Option<&'static str> {
    get().zones.get(usize::from(id)).copied()
}

pub(crate) fn place(id: u16) -> Option<&'static Place> {
    get().places.get(usize::from(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_parses_and_is_large_enough() {
        let p = get();
        assert!(p.places.len() >= 600, "{} places", p.places.len());
        assert!(p.names.len() > p.places.len());
        assert!(zone_id("Asia/Tokyo").is_some());
    }

    #[test]
    fn every_zone_exists_in_the_system_zoneinfo() {
        let dir = std::path::Path::new("/usr/share/zoneinfo");
        if !dir.exists() {
            return;
        }
        let missing: Vec<&str> = zone_names()
            .iter()
            .copied()
            .filter(|z| !dir.join(z).is_file())
            .collect();
        assert!(missing.is_empty(), "missing zones: {missing:?}");
    }
}
