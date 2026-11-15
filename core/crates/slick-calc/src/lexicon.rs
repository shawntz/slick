//! One sorted table of every name the engine knows: units, currencies, places, zones, months,
//! weekdays, functions, constants and holidays. Built once, searched without allocating.

use crate::currency::CURRENCIES;
use crate::places::{self, ZONE_WORDS};
use crate::units::{
    self, P_GIGA, P_KIBI, P_KILO, P_MEGA, P_PETA, P_TERA, PFX, PFX_DATA, PFX_SMALL, PREFIXES, UNITS, UnitRef,
};
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Func {
    Sqrt,
    Cbrt,
    Abs,
    Round,
    Floor,
    Ceil,
    Trunc,
    Min,
    Max,
    Log,
    Log2,
    Ln,
    Exp,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Sinh,
    Cosh,
    Tanh,
    Sind,
    Cosd,
    Tand,
    Sum,
    Avg,
    Gcd,
    Lcm,
    Fact,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Const {
    Pi,
    E,
    Tau,
    Phi,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Holiday {
    Christmas,
    ChristmasEve,
    BoxingDay,
    NewYear,
    NewYearsEve,
    Halloween,
    Valentines,
    StPatricks,
    IndependenceDay,
    Easter,
    Thanksgiving,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Meaning {
    Unit(UnitRef),
    /// Index into [`CURRENCIES`].
    Currency(u16),
    /// The caller's dollar.
    Dollar,
    Place(u16),
    /// Index into [`ZONE_WORDS`].
    Zone(u16),
    /// 1 to 12.
    Month(u8),
    /// Monday is 0.
    Weekday(u8),
    Func(Func),
    Const(Const),
    /// A power of ten: "thousand" is 3.
    Scale(u8),
    Holiday(Holiday),
}

struct Entry {
    key: Box<str>,
    /// When not empty, the raw text must be exactly this, case included.
    exact: &'static str,
    meaning: Meaning,
}

/// The meanings one span of text has, best first.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Hits {
    items: [Option<Meaning>; 6],
    n: usize,
}

impl Hits {
    fn push(&mut self, m: Meaning) {
        if self.items.iter().take(self.n).any(|x| *x == Some(m)) {
            return;
        }
        if let Some(slot) = self.items.get_mut(self.n) {
            *slot = Some(m);
            self.n += 1;
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.n == 0
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = Meaning> + '_ {
        self.items.iter().take(self.n).filter_map(|m| *m)
    }

    pub(crate) fn unit(&self) -> Option<UnitRef> {
        self.iter()
            .find_map(|m| if let Meaning::Unit(u) = m { Some(u) } else { None })
    }

    pub(crate) fn find<T>(&self, f: impl Fn(Meaning) -> Option<T>) -> Option<T> {
        self.iter().find_map(f)
    }
}

const MONTH_KEYS: &[(&str, u8)] = &[
    ("january", 1),
    ("jan", 1),
    ("february", 2),
    ("feb", 2),
    ("march", 3),
    ("mar", 3),
    ("april", 4),
    ("apr", 4),
    ("may", 5),
    ("june", 6),
    ("jun", 6),
    ("july", 7),
    ("jul", 7),
    ("august", 8),
    ("aug", 8),
    ("september", 9),
    ("sep", 9),
    ("sept", 9),
    ("october", 10),
    ("oct", 10),
    ("november", 11),
    ("nov", 11),
    ("december", 12),
    ("dec", 12),
];

const WEEKDAY_KEYS: &[(&str, u8)] = &[
    ("monday", 0),
    ("mon", 0),
    ("tuesday", 1),
    ("tue", 1),
    ("tues", 1),
    ("wednesday", 2),
    ("wed", 2),
    ("thursday", 3),
    ("thu", 3),
    ("thur", 3),
    ("thurs", 3),
    ("friday", 4),
    ("fri", 4),
    ("saturday", 5),
    ("sat", 5),
    ("sunday", 6),
    ("sun", 6),
];

const FUNC_KEYS: &[(&str, Func)] = &[
    ("sqrt", Func::Sqrt),
    ("cbrt", Func::Cbrt),
    ("abs", Func::Abs),
    ("round", Func::Round),
    ("floor", Func::Floor),
    ("ceil", Func::Ceil),
    ("ceiling", Func::Ceil),
    ("trunc", Func::Trunc),
    ("min", Func::Min),
    ("max", Func::Max),
    ("log", Func::Log),
    ("log10", Func::Log),
    ("lg", Func::Log),
    ("log2", Func::Log2),
    ("lb2", Func::Log2),
    ("ln", Func::Ln),
    ("exp", Func::Exp),
    ("sin", Func::Sin),
    ("cos", Func::Cos),
    ("tan", Func::Tan),
    ("asin", Func::Asin),
    ("acos", Func::Acos),
    ("atan", Func::Atan),
    ("arcsin", Func::Asin),
    ("arccos", Func::Acos),
    ("arctan", Func::Atan),
    ("sinh", Func::Sinh),
    ("cosh", Func::Cosh),
    ("tanh", Func::Tanh),
    ("sind", Func::Sind),
    ("cosd", Func::Cosd),
    ("tand", Func::Tand),
    ("sum", Func::Sum),
    ("total", Func::Sum),
    ("avg", Func::Avg),
    ("average", Func::Avg),
    ("mean", Func::Avg),
    ("gcd", Func::Gcd),
    ("gcf", Func::Gcd),
    ("lcm", Func::Lcm),
    ("fact", Func::Fact),
    ("factorial", Func::Fact),
];

const CONST_KEYS: &[(&str, Const)] = &[
    ("pi", Const::Pi),
    ("π", Const::Pi),
    ("e", Const::E),
    ("tau", Const::Tau),
    ("τ", Const::Tau),
    ("phi", Const::Phi),
    ("φ", Const::Phi),
    ("golden ratio", Const::Phi),
];

const SCALE_KEYS: &[(&str, u8)] = &[
    ("hundred", 2),
    ("thousand", 3),
    ("million", 6),
    ("mln", 6),
    ("billion", 9),
    ("bn", 9),
    ("trillion", 12),
    ("quadrillion", 15),
];

const HOLIDAY_KEYS: &[(&str, Holiday)] = &[
    ("christmas", Holiday::Christmas),
    ("xmas", Holiday::Christmas),
    ("christmas day", Holiday::Christmas),
    ("christmas eve", Holiday::ChristmasEve),
    ("boxing day", Holiday::BoxingDay),
    ("new year", Holiday::NewYear),
    ("new years", Holiday::NewYear),
    ("new years day", Holiday::NewYear),
    ("new year's day", Holiday::NewYear),
    ("new years eve", Holiday::NewYearsEve),
    ("new year's eve", Holiday::NewYearsEve),
    ("nye", Holiday::NewYearsEve),
    ("halloween", Holiday::Halloween),
    ("valentines", Holiday::Valentines),
    ("valentines day", Holiday::Valentines),
    ("valentine's day", Holiday::Valentines),
    ("st patricks day", Holiday::StPatricks),
    ("st. patrick's day", Holiday::StPatricks),
    ("saint patricks day", Holiday::StPatricks),
    ("independence day", Holiday::IndependenceDay),
    ("fourth of july", Holiday::IndependenceDay),
    ("easter", Holiday::Easter),
    ("thanksgiving", Holiday::Thanksgiving),
];

/// Unit spellings that are not a table key plus an SI prefix.
fn special_units() -> Vec<(&'static str, &'static str, &'static str, u8)> {
    // Key, exact form or empty, unit symbol, prefix.
    vec![
        ("cal", "Cal", "cal", P_KILO),
        ("kilo", "", "g", P_KILO),
        ("kilos", "", "g", P_KILO),
        ("kg", "", "g", P_KILO),
        ("kgs", "", "g", P_KILO),
        ("km", "", "m", P_KILO),
        ("kms", "", "m", P_KILO),
        ("cm", "", "m", units::P_CENTI),
        ("mm", "", "m", units::P_MILLI),
        ("mg", "", "g", units::P_MILLI),
        ("ml", "", "L", units::P_MILLI),
        ("cl", "", "L", units::P_CENTI),
        ("ms", "ms", "s", units::P_MILLI),
        ("msec", "", "s", units::P_MILLI),
        ("us", "us", "s", units::P_MICRO),
        ("kb", "", "B", P_KILO),
        ("mb", "", "B", P_MEGA),
        ("gb", "", "B", P_GIGA),
        ("tb", "", "B", P_TERA),
        ("pb", "", "B", P_PETA),
        ("kb", "Kb", "bit", P_KILO),
        ("mb", "Mb", "bit", P_MEGA),
        ("gb", "Gb", "bit", P_GIGA),
        ("tb", "Tb", "bit", P_TERA),
        ("kib", "", "B", P_KIBI),
        ("mib", "", "B", P_KIBI + 1),
        ("gib", "", "B", P_KIBI + 2),
        ("tib", "", "B", P_KIBI + 3),
        ("pib", "", "B", P_KIBI + 4),
        ("kbps", "", "bit/s", P_KILO),
        ("mbps", "", "bit/s", P_MEGA),
        ("gbps", "", "bit/s", P_GIGA),
        ("mbps", "MBps", "B/s", P_MEGA),
        ("mb/s", "MB/s", "B/s", P_MEGA),
        ("gb/s", "GB/s", "B/s", P_GIGA),
        ("mb/s", "Mb/s", "bit/s", P_MEGA),
        ("gb/s", "Gb/s", "bit/s", P_GIGA),
        ("kw", "", "W", P_KILO),
        ("kwh", "", "Wh", P_KILO),
        ("mwh", "", "Wh", P_MEGA),
        ("gwh", "", "Wh", P_GIGA),
        ("kilowatt hour", "", "Wh", P_KILO),
        ("kilowatt hours", "", "Wh", P_KILO),
        ("kj", "", "J", P_KILO),
        ("kcal", "", "cal", P_KILO),
        ("kpa", "", "Pa", P_KILO),
        ("hpa", "", "Pa", units::P_KILO - 1),
        ("mpa", "", "Pa", P_MEGA),
        ("khz", "", "Hz", P_KILO),
        ("mhz", "", "Hz", P_MEGA),
        ("ghz", "", "Hz", P_GIGA),
    ]
}

struct Lexicon {
    entries: Vec<Entry>,
    /// Sorted FNV-1a hashes of every word that can open a calculation: the first word of each
    /// name that can start one, every prefixed unit spelling, and the quick gate's starters.
    gate: Vec<u64>,
}

fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

/// The words the quick gate lets through. A superset is harmless; a missing word would reject
/// real math, so this follows what the parser can start with.
fn gate_words(entries: &[Entry]) -> Vec<u64> {
    let mut out: Vec<u64> = Vec::with_capacity(entries.len() * 2);
    let mut buf = [0u8; KEY_MAX];
    let mut add = |word: &str, out: &mut Vec<u64>| {
        if let Some(k) = normalize(word, &mut buf) {
            let first = k.split(' ').next().unwrap_or(k);
            out.push(fnv(first.as_bytes()));
        }
    };
    for e in entries {
        let opens = matches!(
            e.meaning,
            Meaning::Unit(_)
                | Meaning::Currency(_)
                | Meaning::Dollar
                | Meaning::Place(_)
                | Meaning::Zone(_)
                | Meaning::Month(_)
                | Meaning::Func(_)
                | Meaning::Const(_)
                | Meaning::Holiday(_)
        );
        if opens {
            add(&e.key, &mut out);
        }
    }
    for w in crate::quick::STARTERS.iter().chain(crate::quick::STANDALONE) {
        add(w, &mut out);
    }
    // Every spelling `prefixed_unit` accepts: "km", "kilometres", "GiB", "µs", "us".
    let mut joined = String::new();
    for (i, u) in UNITS.iter().enumerate() {
        let Ok(id) = u16::try_from(i) else { continue };
        let unit = UnitRef::new(id);
        let mut symbols: Vec<&str> = vec![u.sym];
        symbols.extend(u.keys.iter().filter(|k| k.len() <= 4 && !k.contains(' ')));
        symbols.extend(u.exact.iter());
        let mut names: Vec<&str> = vec![u.one, u.many];
        names.extend(u.keys.iter().filter(|k| k.len() >= 3));
        for (pi, p) in PREFIXES.iter().enumerate().skip(1) {
            let Ok(prefix) = u8::try_from(pi) else { continue };
            let small = matches!(p.factor, units::Factor::R(n, d) if n < d);
            let alt = if p.sym == "µ" {
                "u"
            } else if p.sym == "k" {
                "K"
            } else {
                ""
            };
            for sym in [p.sym, alt].iter().filter(|s| !s.is_empty()) {
                if allows(unit, prefix, p.binary, small, sym) {
                    for s in &symbols {
                        joined.clear();
                        joined.push_str(sym);
                        joined.push_str(s);
                        add(&joined, &mut out);
                    }
                }
            }
            if allows(unit, prefix, p.binary, small, "") {
                for n in &names {
                    joined.clear();
                    joined.push_str(p.name);
                    joined.push_str(n);
                    add(&joined, &mut out);
                }
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// True when `word` can open a calculation. Allocation-free; a hash and a binary search.
pub(crate) fn may_start(word: &str) -> bool {
    let mut buf = [0u8; KEY_MAX];
    let Some(key) = normalize(word, &mut buf) else {
        return false;
    };
    if key.is_empty() {
        return false;
    }
    let gate = &get().gate;
    if gate.binary_search(&fnv(key.as_bytes())).is_ok() {
        return true;
    }
    // "kms", "tbsps": plurals the table does not list.
    key.strip_suffix('s')
        .is_some_and(|stem| stem.len() >= 2 && gate.binary_search(&fnv(stem.as_bytes())).is_ok())
}

fn build() -> Lexicon {
    let mut entries: Vec<Entry> = Vec::with_capacity(4096);
    let mut buf = [0u8; KEY_MAX];
    let mut add = |raw: &str, exact: &'static str, meaning: Meaning| {
        if let Some(key) = normalize(raw, &mut buf) {
            entries.push(Entry {
                key: key.into(),
                exact,
                meaning,
            });
        }
    };
    for (i, u) in UNITS.iter().enumerate() {
        let Ok(id) = u16::try_from(i) else { continue };
        let m = Meaning::Unit(UnitRef::new(id));
        for k in u.keys {
            add(k, "", m);
        }
        for k in u.exact {
            add(k, k, m);
        }
    }
    for (key, exact, sym, prefix) in special_units() {
        if let Some(mut u) = units::by_sym(sym) {
            u.prefix = prefix;
            add(key, exact, Meaning::Unit(u));
        }
    }
    for (i, c) in CURRENCIES.iter().enumerate() {
        let Ok(id) = u16::try_from(i) else { continue };
        let m = Meaning::Currency(id);
        add(c.code, if c.code_needs_caps { c.code } else { "" }, m);
        for n in c.names {
            add(n, "", m);
        }
    }
    for k in ["dollar", "dollars", "buck", "bucks"] {
        add(k, "", Meaning::Dollar);
    }
    if let Some(gbp) = CURRENCIES
        .iter()
        .position(|c| c.code == "GBP")
        .and_then(|i| u16::try_from(i).ok())
    {
        for k in ["pound", "pounds"] {
            add(k, "", Meaning::Currency(gbp));
        }
    }
    let p = places::get();
    for (name, index) in &p.names {
        add(name, "", Meaning::Place(*index));
    }
    for (i, (k, _)) in ZONE_WORDS.iter().enumerate() {
        if let Ok(id) = u16::try_from(i) {
            add(k, "", Meaning::Zone(id));
        }
    }
    for (k, m) in MONTH_KEYS {
        add(k, "", Meaning::Month(*m));
    }
    for (k, d) in WEEKDAY_KEYS {
        add(k, "", Meaning::Weekday(*d));
    }
    for (k, f) in FUNC_KEYS {
        add(k, "", Meaning::Func(*f));
    }
    for (k, c) in CONST_KEYS {
        add(k, "", Meaning::Const(*c));
    }
    for (k, s) in SCALE_KEYS {
        add(k, "", Meaning::Scale(*s));
    }
    for (k, h) in HOLIDAY_KEYS {
        add(k, "", Meaning::Holiday(*h));
    }
    // Exact-case entries sort first within a key, so "Mb" finds megabit before megabyte.
    entries.sort_by(|a, b| a.key.cmp(&b.key).then_with(|| b.exact.len().cmp(&a.exact.len())));
    let gate = gate_words(&entries);
    Lexicon { entries, gate }
}

fn get() -> &'static Lexicon {
    static LEXICON: OnceLock<Lexicon> = OnceLock::new();
    LEXICON.get_or_init(build)
}

/// Builds the tables now instead of on the first query.
pub(crate) fn prepare() {
    let _ = get();
}

pub(crate) const KEY_MAX: usize = 64;

fn fold(c: char) -> Option<&'static str> {
    Some(match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' | 'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Ā' => "a",
        'ç' | 'ć' | 'č' | 'Ç' | 'Č' => "c",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' | 'É' | 'È' | 'Ê' => "e",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'ı' | 'Í' | 'Î' => "i",
        'ñ' | 'ń' | 'ň' | 'Ñ' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' | 'Ó' | 'Ö' | 'Ø' => "o",
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' | 'Ú' | 'Ü' => "u",
        'ý' | 'ÿ' => "y",
        'ß' => "ss",
        'æ' => "ae",
        'œ' => "oe",
        'ł' | 'Ł' => "l",
        'ś' | 'š' | 'ș' | 'ş' | 'Š' | 'Ş' => "s",
        'ź' | 'ż' | 'ž' | 'Ž' => "z",
        'ř' => "r",
        'ğ' => "g",
        'ț' | 'ţ' => "t",
        'đ' | 'ð' => "d",
        _ => return None,
    })
}

/// Lowercases, folds diacritics, drops dots and apostrophes, and turns hyphens and runs of space
/// into one space. Spaces next to "/" go. None when the result would not fit.
pub(crate) fn normalize<'b>(raw: &str, buf: &'b mut [u8; KEY_MAX]) -> Option<&'b str> {
    let mut n = 0usize;
    let mut pending_space = false;
    let mut last = '\0';
    let put = |s: &str, n: &mut usize, buf: &mut [u8; KEY_MAX]| -> Option<()> {
        let bytes = s.as_bytes();
        buf.get_mut(*n..*n + bytes.len())?.copy_from_slice(bytes);
        *n += bytes.len();
        Some(())
    };
    for c in raw.chars() {
        match c {
            ' ' | '\t' | '-' | '_' | '\u{a0}' => pending_space = n > 0,
            '.' | '\'' | '’' | 'ʻ' | ',' => {}
            _ => {
                if pending_space && c != '/' && last != '/' {
                    put(" ", &mut n, buf)?;
                }
                pending_space = false;
                if c.is_ascii() {
                    let lower = [c.to_ascii_lowercase() as u8];
                    put(core::str::from_utf8(&lower).ok()?, &mut n, buf)?;
                } else if let Some(f) = fold(c) {
                    put(f, &mut n, buf)?;
                } else {
                    for lc in c.to_lowercase() {
                        let mut tmp = [0u8; 4];
                        put(lc.encode_utf8(&mut tmp), &mut n, buf)?;
                    }
                }
                last = c;
            }
        }
    }
    core::str::from_utf8(buf.get(..n)?).ok()
}

/// Every meaning of `raw`, matched as a whole.
pub(crate) fn lookup(raw: &str) -> Hits {
    let mut hits = Hits::default();
    let mut buf = [0u8; KEY_MAX];
    let Some(key) = normalize(raw, &mut buf) else {
        return hits;
    };
    if key.is_empty() {
        return hits;
    }
    let lex = get();
    let start = lex.entries.partition_point(|e| &*e.key < key);
    for e in lex.entries.iter().skip(start) {
        if &*e.key != key {
            break;
        }
        if e.exact.is_empty() || e.exact == raw.trim() {
            hits.push(e.meaning);
        }
    }
    if hits.unit().is_none()
        && !raw.trim().contains(' ')
        && let Some(u) = prefixed_unit(raw.trim())
    {
        hits.push(Meaning::Unit(u));
    }
    // "kms", "tbsps": a plural the table does not list.
    if hits.is_empty()
        && let Some(stem) = raw.trim().strip_suffix('s')
        && stem.len() >= 2
    {
        let inner = lookup_units_only(stem);
        if let Some(u) = inner {
            hits.push(Meaning::Unit(u));
        }
    }
    hits
}

fn lookup_units_only(raw: &str) -> Option<UnitRef> {
    let mut buf = [0u8; KEY_MAX];
    let key = normalize(raw, &mut buf)?;
    let lex = get();
    let start = lex.entries.partition_point(|e| &*e.key < key);
    for e in lex.entries.iter().skip(start) {
        if &*e.key != key {
            break;
        }
        if let Meaning::Unit(u) = e.meaning
            && (e.exact.is_empty() || e.exact == raw)
        {
            return Some(u);
        }
    }
    prefixed_unit(raw)
}

/// A unit written with an SI or binary prefix: "km", "kilometres", "GiB", "µs".
fn prefixed_unit(raw: &str) -> Option<UnitRef> {
    if raw.len() < 2 {
        return None;
    }
    for (pi, p) in PREFIXES.iter().enumerate().skip(1) {
        let Ok(prefix) = u8::try_from(pi) else { continue };
        let small = matches!(p.factor, units::Factor::R(n, d) if n < d);
        // Symbol prefixes keep their case. "u" stands in for micro, "K" for kilo in data units.
        let mut syms = [p.sym, ""];
        if p.sym == "µ" {
            syms[1] = "u";
        } else if p.sym == "k" {
            syms[1] = "K";
        }
        for s in syms.iter().filter(|s| !s.is_empty()) {
            if let Some(rest) = raw.strip_prefix(s)
                && let Some(u) = base_unit(rest, true)
                && allows(u, prefix, p.binary, small, s)
            {
                return Some(UnitRef { id: u.id, prefix });
            }
        }
        if raw.len() > p.name.len() + 2
            && let Some(head) = raw.get(..p.name.len())
            && head.eq_ignore_ascii_case(p.name)
            && let Some(rest) = raw.get(p.name.len()..)
            && let Some(u) = base_unit(rest, false)
            && allows(u, prefix, p.binary, small, "")
        {
            return Some(UnitRef { id: u.id, prefix });
        }
    }
    None
}

fn allows(u: UnitRef, _prefix: u8, binary: bool, small: bool, sym: &str) -> bool {
    let flags = u.flags();
    if flags & PFX_DATA != 0 {
        return !small;
    }
    if binary || sym == "K" || flags & PFX == 0 {
        return false;
    }
    flags & PFX_SMALL == 0 || small
}

/// A unit without a prefix, by symbol with its case or by name in any case.
fn base_unit(rest: &str, symbol: bool) -> Option<UnitRef> {
    let mut buf = [0u8; KEY_MAX];
    let key = normalize(rest, &mut buf)?;
    let lex = get();
    let start = lex.entries.partition_point(|e| &*e.key < key);
    for e in lex.entries.iter().skip(start) {
        if &*e.key != key {
            break;
        }
        let Meaning::Unit(u) = e.meaning else { continue };
        if u.prefix != 0 {
            continue;
        }
        let def = u.def()?;
        if symbol {
            // The symbol must match exactly: "m" after "k", not "M".
            let exact = !e.exact.is_empty() && e.exact == rest;
            if exact || def.sym == rest || def.keys.contains(&rest) && rest.chars().all(|c| !c.is_ascii_uppercase()) {
                return Some(u);
            }
        } else if rest.len() >= 3
            && (def.one.eq_ignore_ascii_case(rest)
                || def.many.eq_ignore_ascii_case(rest)
                || def.keys.iter().any(|k| k.len() >= 3 && k.eq_ignore_ascii_case(rest)))
        {
            return Some(u);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit_sym(raw: &str) -> Option<String> {
        let u = lookup(raw).unit()?;
        let p = u.prefix_def()?;
        Some(format!("{}{}", p.sym, u.def()?.sym))
    }

    #[test]
    fn units_with_prefixes_and_case() {
        assert_eq!(unit_sym("km").as_deref(), Some("km"));
        assert_eq!(unit_sym("kilometres").as_deref(), Some("km"));
        assert_eq!(unit_sym("Mb").as_deref(), Some("Mbit"));
        assert_eq!(unit_sym("MB").as_deref(), Some("MB"));
        assert_eq!(unit_sym("mb").as_deref(), Some("MB"));
        assert_eq!(unit_sym("GiB").as_deref(), Some("GiB"));
        assert_eq!(unit_sym("µs").as_deref(), Some("µs"));
        assert_eq!(unit_sym("ms").as_deref(), Some("ms"));
        assert_eq!(unit_sym("Ms"), None, "seconds take no mega");
        assert_eq!(unit_sym("cd"), None, "days take no prefix");
        assert_eq!(unit_sym("kWh").as_deref(), Some("kWh"));
        assert_eq!(unit_sym("Cal").as_deref(), Some("kcal"));
        assert_eq!(unit_sym("cal").as_deref(), Some("cal"));
        assert_eq!(unit_sym("feet").as_deref(), Some("ft"));
        assert_eq!(unit_sym("megabytes").as_deref(), Some("MB"));
        assert_eq!(unit_sym("K").as_deref(), Some("K"));
        assert_eq!(unit_sym("k"), None);
    }

    #[test]
    fn places_fold_diacritics_and_punctuation() {
        let is_place = |s: &str| lookup(s).iter().any(|m| matches!(m, Meaning::Place(_)));
        assert!(is_place("São Paulo"));
        assert!(is_place("sao paulo"));
        assert!(is_place("St. Petersburg"));
        assert!(is_place("port-au-prince"));
        assert!(is_place("new york"));
        assert!(may_start("new"), "new york");
        assert!(may_start("kilometres"));
        assert!(may_start("GiB"));
        assert!(may_start("kms"));
        assert!(!may_start("safari"));
        assert!(!may_start("notes"));
    }
}
